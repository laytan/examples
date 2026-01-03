package main

import "base:runtime"
import "core:fmt"
import "core:nbio"

import lua "vendor:lua/5.4"

CODE :: `
local nbio = require("nbio")

nbio.open("README.md", function(op)
	if op.err ~= 0 then
		print("ERR: ", op.err)
	else
		print(op.handle)
	end
end)
`

main :: proc() {
	nbio.acquire_thread_event_loop()
	defer nbio.release_thread_event_loop()

	L := lua.L_newstate()
	defer lua.close(L)

	lua.L_openlibs(L)

	{
		Lua_Operation :: struct {
			L:            ^lua.State,
			op:           ^nbio.Operation,
			callback_ref, self_ref: i32,
		}

		// open :: proc(path: string, cb: proc(op: ^nbio.Operation), flags: nbio.File_Flags, perm: nbio.Permissions, dir: nbio.Handle)
		nbio_open :: proc "c" (L: ^lua.State) -> i32 {
			path := lua.L_checkstring(L, 1)
			lua.L_checktype(L, 2, i32(lua.TFUNCTION))

			flags := nbio.File_Flags{.Read}
			perm  := nbio.Permissions_Default_File
			dir   := nbio.CWD

			if !lua.isnoneornil(L, 3) {
				flags = transmute(nbio.File_Flags)lua.L_checkinteger(L, 3)
			}
			if !lua.isnoneornil(L, 4) {
				perm = transmute(nbio.Permissions)u32(lua.L_checkinteger(L, 4))
			}
			if !lua.isnoneornil(L, 5) {
				dir = cast(nbio.Handle)lua.L_checkinteger(L, 5)
			}

			lop := cast(^Lua_Operation)lua.newuserdata(L, size_of(Lua_Operation))

			lua.L_getmetatable(L, "Operation")
			lua.setmetatable(L, -2)

			lop.L = L

			lua.pushvalue(L, -1)
			lop.self_ref = lua.L_ref(L, lua.REGISTRYINDEX)

			lua.pushvalue(L, 2)
			lop.callback_ref = lua.L_ref(L, lua.REGISTRYINDEX)

			context = runtime.default_context()
			lop.op = nbio.open(
				string(path),
				lop,
				nbio_open_callback,
				flags,
				perm,
				dir,
			)

			return 1

			nbio_open_callback :: proc(op: ^nbio.Operation) {
				lop := cast(^Lua_Operation)op.user_data[0]
				L   := lop.L

				lua.rawgeti(L, lua.REGISTRYINDEX, cast(lua.Integer)lop.callback_ref)
				lua.rawgeti(L, lua.REGISTRYINDEX, cast(lua.Integer)lop.self_ref)

				assert(lua.type(L, -1) == .USERDATA)
				if cast(lua.Status)lua.pcall(L, 1, 0, 0) != lua.OK {
					err := lua.tostring(L, -1)
					fmt.eprintln(err)
					lua.pop(L, 1)
				}

				lua.L_unref(L, lua.REGISTRYINDEX, lop.callback_ref)
				lua.L_unref(L, lua.REGISTRYINDEX, lop.self_ref)
				lop.callback_ref = lua.NOREF
				lop.op = nil
			}
		}

		require_nbio :: proc "c" (L: ^lua.State) -> i32 {

			operation_index :: proc "c" (L: ^lua.State) -> i32 {
				lop := cast(^Lua_Operation)lua.L_checkudata(L, 1, "Operation")
				key := string(lua.L_checkstring(L, 2))

				#partial switch lop.op.type {
				case .Open:
					switch key {
					case "handle":
						lua.pushinteger(L, cast(lua.Integer)lop.op.open.handle)
					case "err":
						lua.pushinteger(L, cast(lua.Integer)lop.op.open.err)
					case:
						lua.pushnil(L)
					}
				case:
					lua.pushnil(L)
				}

				return 1
			}

			operation_gc :: proc "c" (L: ^lua.State) -> i32 {
				lop := cast(^Lua_Operation)lua.L_checkudata(L, 1, "Operation")

				if lop.callback_ref != lua.NOREF {
					lua.L_unref(L, lua.REGISTRYINDEX, lop.callback_ref)
				}

				return 0
			}

			lua.L_newmetatable(L, "Operation")

			lua.pushcfunction(L, operation_index)
			lua.setfield(L, -2, "__index")

			lua.pushcfunction(L, operation_gc)
			lua.setfield(L, -2, "__gc")

			lua.pop(L, 1)

			nbio_funcs := [?]lua.L_Reg{
				{"open", nbio_open},
				{nil, nil},
			}
			lua.L_newlib(L, nbio_funcs[:])

			return 1
		}

		lua.L_requiref(L, "nbio", require_nbio, 1)
		lua.pop(L, 1)
	}

	if lua.L_dostring(L, CODE) != 0 {
		error := lua.tostring(L, -1)
		fmt.eprintln(error)
		lua.pop(L, 1)
	}

	err := nbio.run()
	assert(err == nil)
}
