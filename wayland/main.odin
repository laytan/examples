/*
Port of [[ Wayland From Scratch; https://gaultier.github.io/blog/wayland_from_scratch.html ]] into Odin.

Differences:
- no ping/pong, didn't need it
- wayland logo does not need to be converted into ppm, I used `core:image/png` to parse the PNG source
*/
package main

import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import "core:image/png"
import "core:math/rand"
import "core:slice"
import "core:sys/posix"

WAYLAND_LOGO :: #load("wayland.png")

main :: proc() {
	logo, err := png.load_from_bytes(WAYLAND_LOGO)
	if err != nil {
		fmt.eprintfln("load wayland.png: err=%v", err)
		posix.exit(1)
	}
	defer png.destroy(logo)
	assert(logo.channels == 4)

	socket, ok := wayland_wl_display_connect()
	if !ok {
		posix.perror("wayland_wl_display_connect")
		posix.exit(1)
	}
	defer posix.close(socket)

	registry, regok := wayland_wl_display_get_registry(socket)
	if !regok {
		posix.perror("wayland_wl_display_get_registry")
		posix.exit(1)
	}

	state := State {
		wl_registry = registry,
		w = u32(logo.width),
		h = u32(logo.height),
		stride = u32(logo.width * logo.channels),
	}

	if !create_shared_memory_file(&state, state.h * state.stride) {
		posix.perror("create_shared_memory_file")
		posix.exit(1)
	}
	defer posix.close(state.shm_fd)

	for {
		read_buf: [4096]byte
		read_bytes := posix.recv(socket, &read_buf, size_of(read_buf), {.NOSIGNAL})
		if read_bytes < 0 {
			posix.perror("recv")
			posix.exit(1)
		} else if read_bytes == 0 {
			fmt.eprintln("wayland server closed connection")
			posix.exit(1)
		}

		read := read_buf[:read_bytes]
		for len(read) > 0 {
			read = wayland_handle_message(&state, socket, read)
		}

		if state.wl_compositor != 0 && state.wl_shm != 0 && state.xdg_wm_base != 0 && state.wl_surface == 0 {
			assert(state.state == .None)

			state.wl_surface = wayland_wl_compositor_create_surface(&state, socket)
			state.xdg_surface = wayland_xdg_wm_base_get_xdg_surface(&state, socket)
			state.xdg_toplevel = wayland_xdg_surface_get_toplevel(&state, socket)
			wayland_wl_surface_commit(&state, socket)
		}

		if state.state == .Surface_Acked_Configure {
			assert(state.wl_surface   != 0)
			assert(state.xdg_surface  != 0)
			assert(state.xdg_toplevel != 0)

			if state.wl_shm_pool == 0 {
				state.wl_shm_pool = wayland_wl_shm_create_pool(&state, socket)
			}
			if state.wl_buffer == 0 {
				state.wl_buffer = wayland_wl_shm_pool_create_buffer(&state, socket)
			}

			assert(state.shm_pool_data != nil)

			logo_pixels  := slice.reinterpret([][4]u8, logo.pixels.buf[:])
			frame_pixels := slice.reinterpret([]u32,   state.shm_pool_data)
			assert(len(logo_pixels) == len(frame_pixels))

			#no_bounds_check for &frame_pixel, i in frame_pixels {
				px := logo_pixels[i]
				frame_pixel = (u32(px.r) << 16) | (u32(px.g) << 8) | (u32(px.b))
			}

			wayland_wl_surface_attach(&state, socket)
			wayland_wl_surface_commit(&state, socket)

			state.state = .Surface_Attached
		}
	}
}

State_State :: enum {
	None,
	Surface_Acked_Configure,
	Surface_Attached,
}

State :: struct {
	wl_registry:   u32,
	wl_shm:        u32,
	wl_shm_pool:   u32,
	wl_buffer:     u32,
	xdg_wm_base:   u32,
	xdg_surface:   u32,
	wl_compositor: u32,
	wl_surface:    u32,
	xdg_toplevel:  u32,
	stride:        u32,
	w:             u32,
	h:             u32,
	shm_fd:        posix.FD,
	shm_pool_data: []byte `fmt:"-"`,

	state: State_State,
}

WAYLAND_DISPLAY_OBJECT_ID :: 1
WAYLAND_HEADER_SIZE       :: 8
COLOR_CHANNELS            :: 4
WAYLAND_FORMAT_XRGB8888   :: 1

WAYLAND_WL_REGISTRY_EVENT_GLOBAL     :: 0
WAYLAND_WL_DISPLAY_ERROR_EVENT       :: 0
WAYLAND_SHM_POOL_EVENT_FORMAT        :: 0
WAYLAND_XDG_TOPLEVEL_EVENT_CONFIGURE :: 0
WAYLAND_XDG_SURFACE_EVENT_CONFIGURE  :: 0

WAYLAND_WL_REGISTRY_BIND_OPCODE             :: 0
WAYLAND_WL_DISPLAY_GET_REGISTRY_OPCODE      :: 1
WAYLAND_WL_COMPOSITOR_CREATE_SURFACE_OPCODE :: 0
WAYLAND_XDG_WM_BASE_GET_XDG_SURFACE_OPCODE  :: 2
WAYLAND_XDG_SURFACE_GET_TOPLEVEL_OPCODE     :: 1
WAYLAND_WL_SURFACE_COMMIT_OPCODE            :: 6
WAYLAND_WL_SHM_CREATE_POOL_OPCODE           :: 0
WAYLAND_WL_SHM_POOL_CREATE_BUFFER_OPCODE    :: 0
WAYLAND_WL_SURFACE_ATTACH_OPCODE            :: 1
WAYLAND_XDG_SURFACE_ACK_CONFIGURE_OPCODE    :: 4

g_wayland_current_id: u32 = 1

wayland_wl_display_connect :: proc() -> (socket: posix.FD, ok: bool) {
	xdg_runtime_dir := string(posix.getenv("XDG_RUNTIME_DIR"))
	if xdg_runtime_dir == "" {
		posix.errno(.EINVAL)
		return
	}

	wayland_display := string(posix.getenv("WAYLAND_DISPLAY"))
	if wayland_display == "" {
		wayland_display = "wayland-0"
	}

	addr: posix.sockaddr_un
	addr.sun_family = .UNIX

	socket_path_len: int
	socket_path_len += copy(addr.sun_path[socket_path_len:], xdg_runtime_dir)
	socket_path_len += copy(addr.sun_path[socket_path_len:], "/")
	socket_path_len += copy(addr.sun_path[socket_path_len:], wayland_display)

	if socket_path_len == size_of(addr.sun_path) {
		posix.errno(.ENAMETOOLONG)
		return
	}

	socket = posix.socket(.UNIX, .STREAM)
	if socket == -1 {
		return
	}
	defer if !ok { posix.close(socket) }

	if posix.connect(socket, (^posix.sockaddr)(&addr), size_of(addr)) != .OK {
		return
	}

	ok = true
	return
}

wayland_wl_display_get_registry :: proc(socket: posix.FD) -> (u32, bool) {
	msg: [128]byte
	n: int
	n += buf_write_u32(msg[n:], WAYLAND_DISPLAY_OBJECT_ID)
	n += buf_write_u16(msg[n:], WAYLAND_WL_DISPLAY_GET_REGISTRY_OPCODE)

	MSG_ANNOUNCED_SIZE :: WAYLAND_HEADER_SIZE + size_of(g_wayland_current_id)
	assert(roundup_4(MSG_ANNOUNCED_SIZE) == MSG_ANNOUNCED_SIZE)
	n += buf_write_u16(msg[n:], MSG_ANNOUNCED_SIZE)

	g_wayland_current_id += 1
	n += buf_write_u32(msg[n:], g_wayland_current_id)

	assert(n < size_of(msg))

	sent := posix.send(socket, &msg, uint(n), {.NOSIGNAL})
	if sent < 0 {
		return 0, false
	}
	assert(sent == n)

	fmt.printfln("-> wl_display@%v.get_registry: wl_registry=%v", WAYLAND_DISPLAY_OBJECT_ID, g_wayland_current_id)

	return g_wayland_current_id, true
}

wayland_handle_message :: proc(state: ^State, socket: posix.FD, msg: []byte) -> []byte {
	msg := msg
	assert(len(msg) >= 8)

	object_id: u32
	object_id, msg = buf_read_u32(msg)
	assert(object_id <= g_wayland_current_id)

	opcode: u16
	opcode, msg = buf_read_u16(msg)

	announced_size: u16
	announced_size, msg = buf_read_u16(msg)
	assert(roundup_4(announced_size) <= announced_size)

	header_size := size_of(object_id) + size_of(opcode) + size_of(announced_size)
	assert(int(announced_size) <= header_size + len(msg))

	switch {
	case object_id == state.wl_registry && opcode == WAYLAND_WL_REGISTRY_EVENT_GLOBAL:
		name: u32
		name, msg = buf_read_u32(msg)

		interface: string
		interface, msg = buf_read_string(msg)

		version: u32
		version, msg = buf_read_u32(msg)

		fmt.printfln("<- wl_registry@%v.global: name=%v interface=%v version=%v", state.wl_registry, name, interface, version)

		switch interface {
		case "wl_shm":
			state.wl_shm = wayland_wl_registry_bind(socket, state.wl_registry, name, interface, version)
		case "xdg_wm_base":
			state.xdg_wm_base = wayland_wl_registry_bind(socket, state.wl_registry, name, interface, version)
		case "wl_compositor":
			state.wl_compositor = wayland_wl_registry_bind(socket, state.wl_registry, name, interface, version)
		}

	case object_id == WAYLAND_DISPLAY_OBJECT_ID && opcode == WAYLAND_WL_DISPLAY_ERROR_EVENT:
		target_object_id: u32
		target_object_id, msg = buf_read_u32(msg)

		code: u32
		code, msg = buf_read_u32(msg)

		error: string
		error, msg = buf_read_string(msg)

		fmt.eprintfln("fatal error: target_object_id=%v code=%v error=%v", target_object_id, code, error)
		posix.exit(1)

	case object_id == state.wl_shm && opcode == WAYLAND_SHM_POOL_EVENT_FORMAT:
		format: u32
		format, msg = buf_read_u32(msg)
		fmt.printfln("<- wl_shm: format=%x", format)

	case object_id == state.xdg_toplevel && opcode == WAYLAND_XDG_TOPLEVEL_EVENT_CONFIGURE:
		w, h: u32
		w, msg = buf_read_u32(msg)
		h, msg = buf_read_u32(msg)

		states: string
		states, msg = buf_read_string(msg)

		fmt.printfln("<- xdg_toplevel@%v.configure: w=%v h=%v states[%v]", state.xdg_toplevel, w, h, len(states))
	
	case object_id == state.xdg_surface && opcode == WAYLAND_XDG_SURFACE_EVENT_CONFIGURE:
		configure: u32
		configure, msg = buf_read_u32(msg)
		fmt.printfln("<- xdg_surface@%v.configure: configure=%v", state.xdg_surface, configure)
		wayland_xdg_surface_ack_configure(state, socket, configure)
		state.state = .Surface_Acked_Configure

	case:
		fmt.eprintfln("unknown event: state=%v object_id=%v opcode=%v", state, object_id, opcode)

		// skip the message.
		msg = msg[announced_size-u16(header_size):]
	}

	return msg
}

create_shared_memory_file :: proc(state: ^State, size: u32) -> bool {
	name: [255]byte
	for &b in name[:size_of(name)-1] {
		b = byte(rand.uint_range('a', 'z'))
	}

	fd := posix.shm_open(cstring(&name[0]), {.RDWR, .EXCL, .CREAT}, {.IRUSR, .IWUSR})
	if fd < 0 {
		return false
	}

	if posix.shm_unlink(cstring(&name[0])) != .OK {
		return false
	}

	if posix.ftruncate(fd, posix.off_t(size)) != .OK {
		return false
	}

	data := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.SHARED}, fd)
	if data == posix.MAP_FAILED {
		return false
	}

	state.shm_pool_data = ([^]byte)(data)[:size]
	state.shm_fd        = fd
	return true
}

wayland_wl_registry_bind :: proc(socket: posix.FD, registry: u32, name: u32, interface: string, version: u32) -> u32 {
	n: int
	msg: [512]byte
	
	n += buf_write_u32(msg[n:], registry)
	n += buf_write_u16(msg[n:], WAYLAND_WL_REGISTRY_BIND_OPCODE)

	msg_announced_size := u16(WAYLAND_HEADER_SIZE + size_of(name) + size_of(u32) + roundup_4(len(interface)) + size_of(version) + size_of(g_wayland_current_id))
	assert(roundup_4(msg_announced_size) == msg_announced_size)
	n += buf_write_u16(msg[n:], msg_announced_size)

	n += buf_write_u32(msg[n:], name)
	n += buf_write_string(msg[n:], interface)
	n += buf_write_u32(msg[n:], version)

	g_wayland_current_id += 1
	n += buf_write_u32(msg[n:], g_wayland_current_id)

	assert(n < len(msg))

	sent := posix.send(socket, &msg, uint(n), {.NOSIGNAL})
	if sent < 0 {
		posix.perror("wayland_wl_registry_bind")
		posix.exit(1)
	}
	assert(sent == n)

	fmt.printfln("-> wl_registry@%v.bind: name=%v interface=%v version=%v", registry, name, interface, version)

	return g_wayland_current_id
}

wayland_wl_compositor_create_surface :: proc(state: ^State, socket: posix.FD) -> u32 {
	assert(state.wl_compositor > 0)

	n: int
	msg: [128]byte

	n += buf_write_u32(msg[n:], state.wl_compositor)
	n += buf_write_u16(msg[n:], WAYLAND_WL_COMPOSITOR_CREATE_SURFACE_OPCODE)

	msg_announced_size := u16(WAYLAND_HEADER_SIZE + size_of(g_wayland_current_id))
	n += buf_write_u16(msg[n:], msg_announced_size)

	g_wayland_current_id += 1
	n += buf_write_u32(msg[n:], g_wayland_current_id)

	assert(n < len(msg))

	sent := posix.send(socket, &msg, uint(n), {.NOSIGNAL})
	if sent < 0 {
		posix.perror("wayland_wl_compositor_create_surface")
		posix.exit(1)
	}
	assert(sent == n)

	fmt.printfln("-> wl_compositor@%v.create_surface: wl_surface=%v", state.wl_compositor, g_wayland_current_id)

	return g_wayland_current_id
}

wayland_xdg_wm_base_get_xdg_surface :: proc(state: ^State, socket: posix.FD) -> u32 {
	assert(state.xdg_wm_base > 0)
	assert(state.wl_surface > 0)

	n: int
	msg: [128]byte

	n += buf_write_u32(msg[n:], state.xdg_wm_base)
	n += buf_write_u16(msg[n:], WAYLAND_XDG_WM_BASE_GET_XDG_SURFACE_OPCODE)

	msg_announced_size := u16(WAYLAND_HEADER_SIZE + size_of(g_wayland_current_id) + size_of(state.wl_surface))
	n += buf_write_u16(msg[n:], msg_announced_size)

	g_wayland_current_id += 1
	n += buf_write_u32(msg[n:], g_wayland_current_id)

	n += buf_write_u32(msg[n:], state.wl_surface)

	assert(n < len(msg))

	sent := posix.send(socket, &msg, uint(n), {.NOSIGNAL})
	if sent < 0 {
		posix.perror("wayland_xdg_wm_base_get_xdg_surface")
		posix.exit(1)
	}
	assert(sent == n)

	fmt.printfln("-> xdg_wm_base@%v.get_xdg_surface: xdg_surface=%v wl_surface=%v", state.xdg_wm_base, g_wayland_current_id, state.wl_surface)

	return g_wayland_current_id
}

wayland_xdg_surface_get_toplevel :: proc(state: ^State, socket: posix.FD) -> u32 {
	assert(state.xdg_surface > 0)

	n: int
	msg: [128]byte

	n += buf_write_u32(msg[n:], state.xdg_surface)
	n += buf_write_u16(msg[n:], WAYLAND_XDG_SURFACE_GET_TOPLEVEL_OPCODE)

	msg_announced_size := u16(WAYLAND_HEADER_SIZE + size_of(g_wayland_current_id))
	n += buf_write_u16(msg[n:], msg_announced_size)

	g_wayland_current_id += 1
	n += buf_write_u32(msg[n:], g_wayland_current_id)

	assert(n < len(msg))

	sent := posix.send(socket, &msg, uint(n), {.NOSIGNAL})
	if sent < 0 {
		posix.perror("wayland_xdg_surface_get_toplevel")
		posix.exit(1)
	}
	assert(sent == n)

	fmt.printfln("-> xdg_surface@%v.get_toplevel: xdg_toplevel=%v", state.xdg_surface, g_wayland_current_id)

	return g_wayland_current_id
}

wayland_wl_surface_commit :: proc(state: ^State, socket: posix.FD) {
	assert(state.wl_surface > 0)

	n: int
	msg: [128]byte

	n += buf_write_u32(msg[n:], state.wl_surface)
	n += buf_write_u16(msg[n:], WAYLAND_WL_SURFACE_COMMIT_OPCODE)

	msg_announced_size := u16(WAYLAND_HEADER_SIZE)
	n += buf_write_u16(msg[n:], msg_announced_size)

	assert(n < len(msg))

	sent := posix.send(socket, &msg, uint(n), {.NOSIGNAL})
	if sent < 0 {
		posix.perror("wayland_wl_surface_commit")
		posix.exit(1)
	}
	assert(sent == n)

	fmt.printfln("-> wl_surface@%v.commit: ", state.wl_surface)
}

wayland_wl_shm_create_pool :: proc(state: ^State, socket: posix.FD) -> u32 {
	assert(state.shm_pool_data != nil)

	n: int
	msg: [128]byte

	n += buf_write_u32(msg[n:], state.wl_shm)
	n += buf_write_u16(msg[n:], WAYLAND_WL_SHM_CREATE_POOL_OPCODE)

	msg_announced_size := u16(WAYLAND_HEADER_SIZE + size_of(g_wayland_current_id) + size_of(u32))
	n += buf_write_u16(msg[n:], msg_announced_size)

	g_wayland_current_id += 1
	n += buf_write_u32(msg[n:], g_wayland_current_id)

	n += buf_write_u32(msg[n:], u32(len(state.shm_pool_data)))

	bufsize := CMSG_SPACE(size_of(state.shm_fd))
	buf     := ([^]byte)(intrinsics.alloca(bufsize, runtime.DEFAULT_ALIGNMENT))[:bufsize]

	iov := transmute(posix.iovec)(msg[:n])
	msghdr := posix.msghdr {
		msg_iov        = &iov,
		msg_iovlen     = 1,
		msg_control    = raw_data(buf),
		msg_controllen = bufsize,
	}

	cmsg := posix.CMSG_FIRSTHDR(&msghdr)
	cmsg.cmsg_level = posix.SOL_SOCKET
	cmsg.cmsg_type  = posix.SCM_RIGHTS
	cmsg.cmsg_len   = CMSG_LEN(size_of(state.shm_fd))

	(^posix.FD)(posix.CMSG_DATA(cmsg))^ = state.shm_fd

	sent := posix.sendmsg(socket, &msghdr, {.NOSIGNAL})
	if sent < 0 {
		posix.perror("wayland_shm_create_pool")
		posix.exit(1)
	}

	fmt.printfln("-> wl_shm@%v.create_pool: wl_shm_pool=%v", state.wl_shm, g_wayland_current_id)
	return g_wayland_current_id

	/* WARN: not defined by posix. This is based on my glibc linux headers, I don't know if it is portable */

	CMSG_ALIGN :: #force_inline proc(len: uint) -> uint {
		return (len + size_of(uint) - 1) & ~uint(size_of(uint) - 1)
	}

	CMSG_SPACE :: #force_inline proc(len: uint) -> uint {
		return CMSG_ALIGN(len) + CMSG_ALIGN(size_of(posix.cmsghdr))
	}

	CMSG_LEN :: #force_inline proc(len: uint) -> uint {
		return CMSG_ALIGN(size_of(posix.cmsghdr)) + len
	}
}

wayland_wl_shm_pool_create_buffer :: proc(state: ^State, socket: posix.FD) -> u32 {
	assert(state.wl_shm_pool > 0)

	n: int
	msg: [128]byte
	
	n += buf_write_u32(msg[n:], state.wl_shm_pool)
	n += buf_write_u16(msg[n:], WAYLAND_WL_SHM_POOL_CREATE_BUFFER_OPCODE)

	msg_announced_size := u16(WAYLAND_HEADER_SIZE + size_of(g_wayland_current_id) + (size_of(u32) * 5))

	n += buf_write_u16(msg[n:], msg_announced_size)

	g_wayland_current_id += 1
	n += buf_write_u32(msg[n:], g_wayland_current_id)

	offset: u32
	n += buf_write_u32(msg[n:], offset)
	n += buf_write_u32(msg[n:], state.w)
	n += buf_write_u32(msg[n:], state.h)
	n += buf_write_u32(msg[n:], state.stride)
	n += buf_write_u32(msg[n:], WAYLAND_FORMAT_XRGB8888)

	assert(n < len(msg))
	sent := posix.send(socket, &msg, uint(n), {.NOSIGNAL})
	if sent < 0 {
		posix.perror("wayland_wl_shm_pool_create_buffer")
		posix.exit(1)
	}
	assert(sent == n)

	fmt.printfln("-> wl_shm_pool@%v.create_buffer: wl_buffer=%v", state.wl_shm_pool, g_wayland_current_id)

	return g_wayland_current_id
}

wayland_wl_surface_attach :: proc(state: ^State, socket: posix.FD) {
	assert(state.wl_surface > 0)
	assert(state.wl_buffer > 0)

	n: int
	msg: [128]byte
	
	n += buf_write_u32(msg[n:], state.wl_surface)
	n += buf_write_u16(msg[n:], WAYLAND_WL_SURFACE_ATTACH_OPCODE)

	msg_announced_size := u16(WAYLAND_HEADER_SIZE + size_of(state.wl_buffer) + (size_of(u32) * 2))

	n += buf_write_u16(msg[n:], msg_announced_size)

	n += buf_write_u32(msg[n:], state.wl_buffer)

	x, y: u32
	n += buf_write_u32(msg[n:], x)
	n += buf_write_u32(msg[n:], y)

	assert(n < len(msg))
	sent := posix.send(socket, &msg, uint(n), {.NOSIGNAL})
	if sent < 0 {
		posix.perror("wayland_wl_surface_attach")
		posix.exit(1)
	}
	assert(sent == n)

	fmt.printfln("-> wl_surface@%v.attach: wl_buffer=%v", state.wl_surface, state.wl_buffer)
}

wayland_xdg_surface_ack_configure :: proc(state: ^State, socket: posix.FD, configure: u32) {
	assert(state.xdg_surface > 0)

	n: int
	msg: [128]byte

	n += buf_write_u32(msg[n:], state.xdg_surface)
	n += buf_write_u16(msg[n:], WAYLAND_XDG_SURFACE_ACK_CONFIGURE_OPCODE)

	msg_announced_size := u16(WAYLAND_HEADER_SIZE + size_of(configure))

	n += buf_write_u16(msg[n:], msg_announced_size)

	n += buf_write_u32(msg[n:], configure)

	assert(n < len(msg))
	sent := posix.send(socket, &msg, uint(n), {.NOSIGNAL})
	if sent < 0 {
		posix.perror("wayland_xdg_surface_ack_configure")
		posix.exit(1)
	}
	assert(sent == n)

	fmt.printfln("-> xdg_surface@%v.configure: configure=%v", state.xdg_surface, configure)
}

roundup_4 :: #force_inline proc(n: $T) -> T {
	return (n + 3) & ~T(3)
}

buf_write_u32 :: proc(buf: []byte, x: u32) -> int {
	assert(len(buf) >= size_of(x))
	assert(uintptr(raw_data(buf)) % size_of(x) == 0, "not aligned")
	(^u32)(raw_data(buf))^ = x
	return size_of(x)
}

buf_write_u16 :: proc(buf: []byte, x: u16) -> int {
	assert(len(buf) >= size_of(x))
	assert(uintptr(raw_data(buf)) % size_of(x) == 0, "not aligned")
	(^u16)(raw_data(buf))^ = x
	return size_of(x)
}

buf_write_string :: proc(buf: []byte, str: string) -> int {
	assert(len(str) < int(max(u32)))
	clen := len(str) + 1
	n := buf_write_u32(buf, u32(clen))
	n += copy(buf[n:], str)
	n += 1

	if rounded := roundup_4(clen); rounded != clen {
		pad_len := rounded-clen
		assert(len(buf[n:]) >= pad_len)
		n += pad_len
	}
	return n
}

buf_read_u32 :: proc(buf: []byte) -> (res: u32, left: []byte) {
	assert(len(buf) >= size_of(res))
	assert(uintptr(raw_data(buf)) % size_of(res) == 0, "not aligned")

	res  = (^u32)(raw_data(buf))^
	left = buf[size_of(res):]
	return
}

buf_read_u16 :: proc(buf: []byte) -> (res: u16, left: []byte) {
	assert(len(buf) >= size_of(res))
	assert(uintptr(raw_data(buf)) % size_of(res) == 0, "not aligned")

	res  = (^u16)(raw_data(buf))^
	left = buf[size_of(res):]
	return
}

buf_read_string :: proc(buf: []byte) -> (res: string, left: []byte) {
	left = buf

	strlen: u32
	strlen, left = buf_read_u32(left)
	if strlen == 0 {
		return "", left
	}

	padded_strlen := roundup_4(strlen)

	res  = string(left[:strlen-1])
	left = left[padded_strlen:]
	return
}
