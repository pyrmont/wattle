/* The contract list, included twice by `test/contracts.c` with two different
 * definitions of CONTRACT: once to declare the entry points and once to build
 * the table. Keeping it in one place is the whole point -- a contract is added
 * here and in `build.zig` and nowhere else.
 *
 * Each entry is guarded by the macro `build.zig` defines for the source file
 * it compiled in, so the guards here follow the build's conditions rather than
 * restating them. A contract whose source was not compiled is not declared and
 * not called, and a mismatch is a link error rather than a silent omission. */

#ifdef JANET_CONTRACT_VECTOR
CONTRACT(vector)
#endif
#ifdef JANET_CONTRACT_UTILS
CONTRACT(utils)
#endif
#ifdef JANET_CONTRACT_REGISTRY
CONTRACT(registry)
#endif
#ifdef JANET_CONTRACT_INTSCAN
CONTRACT(intscan)
#endif
#ifdef JANET_CONTRACT_TEXTSCAN
CONTRACT(textscan)
#endif
#ifdef JANET_CONTRACT_REGALLOC
CONTRACT(regalloc)
#endif
#ifdef JANET_CONTRACT_VERIFY
CONTRACT(verify)
#endif
#ifdef JANET_CONTRACT_REMOVE_NOOPS
CONTRACT(remove_noops)
#endif
#ifdef JANET_CONTRACT_MOVOPT
CONTRACT(movopt)
#endif
#ifdef JANET_CONTRACT_EMIT_CORE
CONTRACT(emit_core)
#endif
#ifdef JANET_CONTRACT_ASM_ENCODE
CONTRACT(asm_encode)
#endif
#ifdef JANET_CONTRACT_ASM_DECODE
CONTRACT(asm_decode)
#endif
#ifdef JANET_CONTRACT_DISASM
CONTRACT(disasm)
#endif
#ifdef JANET_CONTRACT_COMPILER_PRIMITIVES
CONTRACT(compiler_primitives)
#endif
#ifdef JANET_CONTRACT_SPECIALS_CORE
CONTRACT(specials_core)
#endif
#ifdef JANET_CONTRACT_NUMSCAN
CONTRACT(numscan)
#endif
#ifdef JANET_CONTRACT_MATH
CONTRACT(math)
#endif
#ifdef JANET_CONTRACT_INTTYPES
CONTRACT(inttypes)
#endif
#ifdef JANET_CONTRACT_OS_PERMISSIONS
CONTRACT(os_permissions)
#endif
#ifdef JANET_CONTRACT_OS_PLATFORM
CONTRACT(os_platform)
#endif
#ifdef JANET_CONTRACT_OS_ENVIRON
CONTRACT(os_environ)
#endif
#ifdef JANET_CONTRACT_OS_FS
CONTRACT(os_fs)
#endif
#ifdef JANET_CONTRACT_OS_STAT
CONTRACT(os_stat)
#endif
#ifdef JANET_CONTRACT_OS_TIME
CONTRACT(os_time)
#endif
#ifdef JANET_CONTRACT_OS_FS_PATHS
CONTRACT(os_fs_paths)
#endif
#ifdef JANET_CONTRACT_OS_PROCESS
CONTRACT(os_process)
#endif
#ifdef JANET_CONTRACT_OS_SURFACE
CONTRACT(os_surface)
#endif
#ifdef JANET_CONTRACT_EV_CORE
CONTRACT(ev_core)
#endif
#ifdef JANET_CONTRACT_FILEWATCH_FLAGS
CONTRACT(filewatch_flags)
#endif
#ifdef JANET_CONTRACT_FILEWATCH_CORE
CONTRACT(filewatch_core)
#endif
#ifdef JANET_CONTRACT_FFI_LAYOUT
CONTRACT(ffi_layout)
#endif
#ifdef JANET_CONTRACT_FFI_CLASSIFY
CONTRACT(ffi_classify)
#endif
#ifdef JANET_CONTRACT_FFI_CORE
CONTRACT(ffi_core)
#endif
#ifdef JANET_CONTRACT_IO_CORE
CONTRACT(io_core)
#endif
#ifdef JANET_CONTRACT_PARSER_CORE
CONTRACT(parser_core)
#endif
#ifdef JANET_CONTRACT_VM_STATE
CONTRACT(vm_state)
#endif
#ifdef JANET_CONTRACT_ARGS_CORE
CONTRACT(args_core)
#endif
#ifdef JANET_CONTRACT_GC_ALLOC
CONTRACT(gc_alloc)
#endif
#ifdef JANET_CONTRACT_GC_MARK
CONTRACT(gc_mark)
#endif
#ifdef JANET_CONTRACT_GC_SWEEP
CONTRACT(gc_sweep)
#endif
#ifdef JANET_CONTRACT_BUFFER_ARRAY
CONTRACT(buffer_array)
#endif
#ifdef JANET_CONTRACT_STRING_SYMBOL
CONTRACT(string_symbol)
#endif
#ifdef JANET_CONTRACT_STRUCT_TABLE
CONTRACT(struct_table)
#endif
#ifdef JANET_CONTRACT_VALUE_ORDER
CONTRACT(value_order)
#endif
#ifdef JANET_CONTRACT_VALUE_ACCESS
CONTRACT(value_access)
#endif
#ifdef JANET_CONTRACT_ABSTRACT_CORE
CONTRACT(abstract_core)
#endif
#ifdef JANET_CONTRACT_VALUE_ALLOC
CONTRACT(value_alloc)
#endif
#ifdef JANET_CONTRACT_PP_DESCRIBE
CONTRACT(pp_describe)
#endif
#ifdef JANET_CONTRACT_PP_PRETTY
CONTRACT(pp_pretty)
#endif
#ifdef JANET_CONTRACT_PP_FORMAT
CONTRACT(pp_format)
#endif
#ifdef JANET_CONTRACT_PEG
CONTRACT(peg)
#endif
#ifdef JANET_CONTRACT_CORE_ENV
CONTRACT(core_env)
#endif
#ifdef JANET_CONTRACT_EV_LOOP
CONTRACT(ev_loop)
#endif
#ifdef JANET_CONTRACT_NET_SOCKETS
CONTRACT(net_sockets)
#endif
#ifdef JANET_CONTRACT_MARSH
CONTRACT(marsh)
#endif
#ifdef JANET_CONTRACT_VALUE_WRAP
CONTRACT(value_wrap)
#endif
#ifdef JANET_CONTRACT_GC_STRESS
CONTRACT(gc_stress)
#endif
#ifdef JANET_CONTRACT_SIGNAL_CORE
CONTRACT(signal_core)
#endif
#ifdef JANET_CONTRACT_TRACE_FRAMES
CONTRACT(trace_frames)
#endif
#ifdef JANET_CONTRACT_VM_RUN
CONTRACT(vm_run)
#endif
#ifdef JANET_CONTRACT_VM_LIFECYCLE
CONTRACT(vm_lifecycle)
#endif
#ifdef JANET_CONTRACT_VM_ENTRY
CONTRACT(vm_entry)
#endif
#ifdef JANET_CONTRACT_VM_CALLS
CONTRACT(vm_calls)
#endif
#ifdef JANET_CONTRACT_FIBER_CORE
CONTRACT(fiber_core)
#endif
