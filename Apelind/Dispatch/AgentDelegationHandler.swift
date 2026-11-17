import ApelinProtocol
import Foundation

/// No worker-supplied plan is installed here. Only the verified opener can
/// advance/amend an existing host record; the child may read/report/admit.
enum AgentDelegationHandler {
    static func handle(_ request: HostRequest, host: SessionHost) async -> HostReply {
        do {
            let action = try request.decode(AgentDelegationRequest.self)
            if request.caller == .app {
                guard action.action == .read else {
                    throw ApelinError(.denied, "Plan changes require the assignment's authenticated opener.")
                }
                let record = try await host.delegations.record(action.sessionID)
                return (.success(request.requestID, AgentDelegationResponse(
                    plan: record?.plan,
                    ledger: try await host.assignments.read(opener: action.sessionID)
                )), [])
            }
            guard case let .worker(.agent, caller?) = request.caller,
                  let entry = await AgentSessionTable.shared.entry(caller),
                  let task = await host.registry.record(entry.task.taskID), !task.state.isTerminal else {
                throw ApelinError(.denied, "Only an agent session may update a delegation.")
            }
            if action.action == .seal {
                guard action.sessionID == caller, let revision = action.expectedRevision else {
                    throw ApelinError(.denied, "Seal your own group using its current group revision.")
                }
                _ = try await host.assignments.seal(opener: caller, expectedRevision: revision)
                await AgentReportRelay.shared.accountChanged(caller)
                return (.success(request.requestID, AgentDelegationResponse(
                    plan: nil, ledger: try await host.assignments.read(opener: caller)
                )), [])
            }
            if [.acceptAssignment, .cancelAssignment, .failAssignment].contains(action.action) {
                guard let saved = try await host.delegations.record(action.sessionID),
                      saved.opener == caller, let revision = action.expectedRevision else {
                    throw ApelinError(.denied, "Only the authenticated opener may dispose of this assignment, using its member revision.")
                }
                switch action.action {
                case .acceptAssignment:
                    _ = try await host.assignments.accept(child: saved.child, opener: caller,
                                                          plan: saved.plan, expectedRevision: revision)
                case .cancelAssignment:
                    _ = try await host.assignments.cancel(child: saved.child, opener: caller,
                                                          reason: action.note ?? "", expectedRevision: revision)
                case .failAssignment:
                    _ = try await host.assignments.fail(child: saved.child, opener: caller,
                                                        reason: action.note ?? "", expectedRevision: revision)
                default: break
                }
                await AgentReportRelay.shared.accountChanged(caller)
                return (.success(request.requestID, AgentDelegationResponse(
                    plan: saved.plan, ledger: try await host.assignments.read(opener: caller)
                )), [])
            }
            // The assignment is authoritative too: a cancelled/failed child may
            // read and report, but cannot keep writing under its old step.
            if action.action != .read,
               let saved = try await host.delegations.record(action.sessionID) {
                guard let member = try await host.assignments.assignment(child: saved.child, opener: saved.opener) else {
                    throw ApelinError(.denied, "This brief has no assignment record. Repair the account before continuing.")
                }
                if member.state.isTerminal,
                   action.action != .admit || action.tool.map({ AgentDelegationToolPolicy.effect(of: $0) == .fileWrite }) != false {
                    throw ApelinError(.denied, "The assignment is \(member.state.rawValue); it authorises no further mutation.")
                }
            }
            if action.action == .admit,
               let tool = action.tool,
               AgentDelegationToolPolicy.effect(of: tool) == .fileWrite {
                guard caller == action.sessionID,
                      let record = try await host.delegations.record(caller), let path = action.path else {
                    throw ApelinError(.denied, "File admission requires this child's brief and relative path.")
                }
                let project = try AgentProjects.resolve(home: host.home, projectID: record.projectID, projectName: nil)
                do { try AgentDelegationPath.validate(path, projectRoot: project.path) }
                catch {
                    throw AgentDelegationViolation(stepID: record.plan.currentStep?.id ?? "end",
                                                   title: record.plan.currentStep?.title ?? "Assignment",
                                                   rule: error.localizedDescription)
                }
            }
            var result = try await host.delegations.apply(action, caller: caller)
            if let saved = try await host.delegations.record(action.sessionID) {
                // What the child says it produced is recorded while the
                // assignment is still working — before the plan transition
                // below moves it. It stays a claim: only a check is evidence.
                if let outputs = action.outputs, !outputs.isEmpty,
                   action.action == .review || action.action == .blocked {
                    _ = try await host.assignments.report(outputs, child: saved.child, opener: saved.opener)
                }
                if let plan = result.plan {
                    _ = try await host.assignments.sync(child: saved.child, opener: saved.opener, plan: plan)
                }
                if action.action != .read && action.action != .admit {
                    await AgentReportRelay.shared.accountChanged(saved.opener)
                }
                // A child gets only its own plan; the opener reads the whole account.
                if caller == saved.opener {
                    result.ledger = try await host.assignments.read(opener: caller)
                }
            } else if action.action == .read, caller == action.sessionID {
                result.ledger = try await host.assignments.read(opener: caller)
            }
            return (.success(request.requestID, result), [])
        } catch let violation as AgentDelegationViolation {
            return request.fail(ApelinError(.denied, violation.localizedDescription))
        } catch {
            return request.fail(error)
        }
    }
}
