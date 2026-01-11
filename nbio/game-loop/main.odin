/*
Example game loop integrated with nbio, using Raylib here.

Showcases a simple async asset loader, textures are assigned a default texture at the start.
When the texture is asked to be loaded it is done so using the event loop.
*/
package main

import "core:nbio"
import "core:log"
import "core:strings"

import rl "vendor:raylib"

Texture :: struct {
	path:   cstring,
	width:  int,
	height: int,
	data:   rl.Texture2D,
}

Texture_Name :: enum {
	Default,
	Raylib_Logo,
}

g_textures := [Texture_Name]Texture{
	.Default     = {"missing.png", 32, 32, {}},
	.Raylib_Logo = {"raylib_logo.png", 256, 256, {}},
}

main :: proc() {
	context.logger = log.create_console_logger()

	nbio.acquire_thread_event_loop()
	defer nbio.release_thread_event_loop()

	rl.InitWindow(800, 600, "nbio")
	defer rl.CloseWindow()

	load_texture(&g_textures[.Default])

	rl.SetTargetFPS(60)

	for !rl.WindowShouldClose() {
		if err := nbio.tick(timeout=0); err != nil {
			log.errorf("nbio.tick: %v", err)
		}

		w, h := f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())

		{
			rl.BeginDrawing()
			defer rl.EndDrawing()

			rl.ClearBackground(rl.RAYWHITE)

			txt := &g_textures[.Raylib_Logo]
			draw_texture(txt^, {w/2 - f32(txt.width)/2, h/2 - f32(txt.height)/2, f32(txt.width), f32(txt.height)}, rl.WHITE)

			if rl.GuiButton({w/2 - f32(txt.width)/2, h/2 + f32(txt.height)/2, f32(txt.width), 50}, "Load texture") {
				if rl.IsTextureReady(txt.data) {
					rl.UnloadTexture(txt.data)
					txt.data = {}
				} else {
					load_texture(txt)
				}
			}
		}
	}
}

draw_texture :: proc(txt: Texture, dest: rl.Rectangle, tint: rl.Color) {
	txt := txt
	if !rl.IsTextureReady(txt.data) {
		txt.data = g_textures[.Default].data
	}

	rl.DrawTexturePro(
		txt.data,
		{0, 0, f32(txt.data.width), f32(txt.data.height)},
		dest,
		{},
		0,
		rl.WHITE,
	)
}

load_texture :: proc(txt: ^Texture) {
	assert(txt.width > 0)
	assert(txt.height > 0)
	assert(txt.path != nil)
	txt.data = g_textures[.Default].data

	nbio.read_entire_file(string(txt.path), txt, on_read)

	on_read :: proc(txt: rawptr, buf: []byte, err: nbio.Read_Entire_File_Error) {
		txt := (^Texture)(txt)
		if err.value != nil {
			log.errorf("load_texture(%q): %v: %v", txt.path, err.operation, err.value)
			return
		}

		spath := string(txt.path)
		i := strings.last_index(spath, ".")
		assert(i > 0)
		ext := spath[i:]

		image := rl.LoadImageFromMemory(cstring(raw_data(ext)), raw_data(buf), i32(len(buf)))
		txt.data = rl.LoadTextureFromImage(image)

		rl.UnloadImage(image)
		delete(buf)

		log.infof("load_texture: %q loaded", txt.path)
	}
}
