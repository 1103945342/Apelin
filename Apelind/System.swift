import Darwin
import Dispatch
import XPC

// Private or Mac-only in the iOS SDK headers, public in libSystem on every iOS
// this app supports. The process questions live in ProcessList.swift, which
// the install tests build without XPC.

@_silgen_name("xpc_connection_create_mach_service")
func daemonCreateMachServiceListener(
    _ name: UnsafePointer<CChar>,
    _ queue: DispatchQueue?,
    _ flags: UInt64,
) -> xpc_connection_t?

@_silgen_name("xpc_connection_get_audit_token")
func daemonConnectionAuditToken(_ connection: xpc_connection_t, _ token: UnsafeMutablePointer<audit_token_t>)

@_silgen_name("xpc_copy_entitlement_for_token")
func daemonCopyEntitlement(_ name: UnsafePointer<CChar>, _ token: UnsafeMutablePointer<audit_token_t>) -> xpc_object_t?

/// `XPC_CONNECTION_MACH_SERVICE_LISTENER`.
let machServiceListener: UInt64 = 1
