// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module util

import os
import v.pref

pub const (
	v_version = '0.1.27'
)

// math.bits is needed by strconv.ftoa
pub const (
	builtin_module_parts = ['math.bits', 'strconv', 'strconv.ftoa', 'hash.wyhash', 'strings']
)

// vhash() returns the build string C.V_COMMIT_HASH . See cmd/tools/gen_vc.v .
pub fn vhash() string {
	mut buf := [50]byte
	buf[0] = 0
	C.snprintf(charptr(buf), 50, '%s', C.V_COMMIT_HASH)
	return tos_clone(buf)
}

pub fn full_hash() string {
	build_hash := vhash()
	current_hash := githash(false)
	if build_hash == current_hash {
		return build_hash
	}
	return '${build_hash}.${current_hash}'
}

// full_v_version() returns the full version of the V compiler
pub fn full_v_version(is_verbose bool) string {
	if is_verbose {
		return 'V ${v_version} ${full_hash()}'
	}
	hash := githash(false)
	return 'V ${v_version} $hash'
}

// githash(x) returns the current git commit hash.
// When x is false, it is very fast - it just returns a predefined C constant.
// When x is true, it tries to get the current commit hash, by parsing the
// relevant files in the .git/ folder, or if that is not possible
// for example when using a V from a V binary release, that does not have .git/
// defaults to getting the predefined C constant again.
// NB: githash(true) must be called only when v detects that it builds itself.
// For all other programs, githash(false) should be used.
pub fn githash(should_get_from_filesystem bool) string {
	for {
		// The `for` construct here is used as a goto substitute.
		// The code in this function will break out of the `for`
		// if it detects an error and can not continue.
		if should_get_from_filesystem {
			vexe := os.getenv('VEXE')
			vroot := os.dir(vexe)
			// .git/HEAD
			git_head_file := os.join_path(vroot, '.git', 'HEAD')
			if !os.exists(git_head_file) {
				break
			}
			// 'ref: refs/heads/master' ... the current branch name
			head_content := os.read_file(git_head_file) or {
				break
			}
			mut current_branch_hash := head_content
			if head_content.starts_with('ref: ') {
				gcbranch_rel_path := head_content.replace('ref: ', '').trim_space()
				gcbranch_file := os.join_path(vroot, '.git', gcbranch_rel_path)
				// .git/refs/heads/master
				if !os.exists(gcbranch_file) {
					break
				}
				// get the full commit hash contained in the ref heads file
				branch_hash := os.read_file(gcbranch_file) or {
					break
				}
				current_branch_hash = branch_hash
			}
			desired_hash_length := 7
			if current_branch_hash.len > desired_hash_length {
				return current_branch_hash[0..desired_hash_length]
			}
		}
		break
	}
	mut buf := [50]byte
	buf[0] = 0
	C.snprintf(charptr(buf), 50, '%s', C.V_CURRENT_COMMIT_HASH)
	return tos_clone(buf)
}

//
pub fn set_vroot_folder(vroot_path string) {
	// Preparation for the compiler module:
	// VEXE env variable is needed so that compiler.vexe_path()
	// can return it later to whoever needs it:
	vname := if os.user_os() == 'windows' { 'v.exe' } else { 'v' }
	os.setenv('VEXE', os.real_path(os.join_path(vroot_path, vname)), true)
}

pub fn launch_tool(is_verbose bool, tool_name string, args []string) {
	vexe := pref.vexe_path()
	vroot := os.dir(vexe)
	set_vroot_folder(vroot)
	tool_args := args_quote_paths_with_spaces(args)
	tool_exe := path_of_executable(os.real_path('$vroot/cmd/tools/$tool_name'))
	tool_source := os.real_path('$vroot/cmd/tools/${tool_name}.v')
	tool_command := '"$tool_exe" $tool_args'
	if is_verbose {
		println('launch_tool vexe        : $vroot')
		println('launch_tool vroot       : $vroot')
		println('launch_tool tool_args   : $tool_args')
		println('launch_tool tool_command: $tool_command')
	}
	// TODO Caching should be done on the `vlib/v` level.
	mut should_compile := false
	if !os.exists(tool_exe) {
		should_compile = true
	} else {
		if os.file_last_mod_unix(tool_exe) <= os.file_last_mod_unix(vexe) {
			// v was recompiled, maybe after v up ...
			// rebuild the tool too just in case
			should_compile = true
			if tool_name == 'vself' || tool_name == 'vup' {
				// The purpose of vself/up is to update and recompile v itself.
				// After the first 'v self' execution, v will be modified, so
				// then a second 'v self' will detect, that v is newer than the
				// vself executable, and try to recompile vself/up again, which
				// will slow down the next v recompilation needlessly.
				should_compile = false
			}
		}
		if os.file_last_mod_unix(tool_exe) <= os.file_last_mod_unix(tool_source) {
			// the user changed the source code of the tool, or git updated it:
			should_compile = true
		}
	}
	if is_verbose {
		println('launch_tool should_compile: $should_compile')
	}
	if should_compile {
		mut compilation_command := '"$vexe" '
		compilation_command += '"$tool_source"'
		if is_verbose {
			println('Compiling $tool_name with: "$compilation_command"')
		}
		tool_compilation := os.exec(compilation_command) or {
			panic(err)
		}
		if tool_compilation.exit_code != 0 {
			mut err := 'Permission denied'
			if !tool_compilation.output.contains('Permission denied') {
				err = '\n$tool_compilation.output'
			}
			eprintln('cannot compile `$tool_source`: $err')
			exit(1)
		}
	}
	if is_verbose {
		println('launch_tool running tool command: $tool_command ...')
	}
	exit(os.system(tool_command))
}

pub fn quote_path_with_spaces(s string) string {
	if s.contains(' ') {
		return '"${s}"'
	}
	return s
}

pub fn args_quote_paths_with_spaces(args []string) string {
	mut res := []string{}
	for a in args {
		res << quote_path_with_spaces(a)
	}
	return res.join(' ')
}

pub fn path_of_executable(path string) string {
	$if windows {
		return path + '.exe'
	}
	return path
}

pub fn read_file(file_path string) ?string {
	mut raw_text := os.read_file(file_path) or {
		return error('failed to open $file_path')
	}
	// BOM check
	if raw_text.len >= 3 {
		c_text := raw_text.str
		if c_text[0] == 0xEF && c_text[1] == 0xBB && c_text[2] == 0xBF {
			// skip three BOM bytes
			offset_from_begin := 3
			raw_text = tos(c_text[offset_from_begin], vstrlen(c_text) - offset_from_begin)
		}
	}
	return raw_text
}

[inline]
pub fn imin(a, b int) int {
	return if a < b {
		a
	} else {
		b
	}
}

[inline]
pub fn imax(a, b int) int {
	return if a > b {
		a
	} else {
		b
	}
}

pub fn replace_op(s string) string {
	last_char := s[s.len - 1]
	suffix := match last_char {
		`+` { '_plus' }
		`-` { '_minus' }
		`*` { '_mult' }
		`/` { '_div' }
		`%` { '_mod' }
		else { '' }
	}
	return s[..s.len - 1] + suffix
}

pub fn join_env_vflags_and_os_args() []string {
	vosargs := os.getenv('VOSARGS')
	if vosargs != '' {
		return non_empty(vosargs.split(' '))
	}
	mut args := []string{}
	vflags := os.getenv('VFLAGS')
	if vflags != '' {
		args << os.args[0]
		args << vflags.split(' ')
		if os.args.len > 1 {
			args << os.args[1..]
		}
		return non_empty(args)
	}
	return non_empty(os.args)
}

fn non_empty(arg []string) []string {
	return arg.filter(it != '')
}
