package main

import "core:fmt"
import "core:io"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

Graph :: struct {
	packages: map[string]^Package,
	entry:    ^Package,
}

Package :: struct {
	name:     string,
	fullpath: string,
	imports:  [dynamic]^Package,
}

Visitor :: struct {
	pkg:         ^ast.Package,
	graph:       ^Graph,
	gpkg:        ^Package,
	collections: map[string]string,
}

main :: proc() {
	if len(os.args) < 2 {
		error("`%v` takes a package as its first argument.", os.args[0])
	}
	package_path := os.args[1]

	graph: Graph

	visitor: Visitor
	visitor.graph = &graph

	visitor.collections["base"]   = ODIN_ROOT + "base"
	visitor.collections["core"]   = ODIN_ROOT + "core"
	visitor.collections["vendor"] = ODIN_ROOT + "vendor"
	visitor.collections["shared"] = ODIN_ROOT + "shared"

	fill_graph(&visitor, package_path)

	s := strings.builder_make()
	write_graph(strings.to_stream(&s), graph)
	fmt.println(strings.to_string(s))
}

write_graph :: proc(s: io.Stream, g: Graph) {
	ws :: io.write_string

	ws(s, "digraph deps {\n")

	for _, pkg in g.packages {
		write_package(s, pkg^)
	}

	ws(s, "}\n")
}

write_package :: proc(s: io.Stream, pkg: Package) {
	ws :: io.write_string

	// ws(s, pkg.name)
	// ws(s, "\tsubgraph ")
	// ws(s, " {\n")
	// ws(s, "\t\tlabel=\"")
	// ws(s, pkg.name)
	// ws(s, "\";\n\n")
	for dep in pkg.imports {
		ws(s, "\t")
		ws(s, pkg.name)
		ws(s, " -> ")
		ws(s, dep.name)
		ws(s, ";\n")
	}
	// ws(s, "\t}\n\n")
}

fill_graph :: proc(gv: ^Visitor, start_pkg: string) {
	parse_ok: bool
	gv.pkg, parse_ok = parser.parse_package_from_path(start_pkg)
	if !parse_ok {
		error("Could not parse package %q.", start_pkg)
	}

	pkg := new(Package)
	pkg.name = gv.pkg.name
	pkg.fullpath = gv.pkg.fullpath

	gv.graph.entry = pkg
	gv.graph.packages[gv.pkg.fullpath] = pkg
	gv.gpkg = pkg

	{
		runtime := new(Package)
		runtime.name     = "runtime"
		runtime.fullpath = filepath.join({ODIN_ROOT + "base", "runtime"})
		gv.graph.packages[runtime.fullpath] = runtime
	}

	{
		builtin := new(Package)
		builtin.name     = "builtin"
		builtin.fullpath = filepath.join({ODIN_ROOT + "base", "builtin"})
		gv.graph.packages[builtin.fullpath] = builtin
	}

	{
		intrinsics := new(Package)
		intrinsics.name     = "intrinsics"
		intrinsics.fullpath = filepath.join({ODIN_ROOT + "base", "intrinsics"})
		gv.graph.packages[intrinsics.fullpath] = intrinsics
	}

	v := ast.Visitor{
		visit = visit,
		data  = gv,
	}
	ast.walk(&v, gv.pkg)
}

visit :: proc(v: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
	if node == nil {
		return nil
	}

	gv := (^Visitor)(v.data)
	#partial switch n in node.derived {
	case ^ast.Package:
		return v
	case ^ast.File:
		tags := parser.parse_file_tags(n^)
		if tags.ignore {
			return nil
		}

		return v
	case ^ast.Import_Decl:
		import_path := n.fullpath[1:len(n.fullpath)-1]
		if colon := strings.index_byte(import_path, ':'); colon >= 0 {
			if colon == 0 || colon == len(import_path)-1 {
				error("Invalid import path %q", import_path)
			}

			collection := import_path[:colon]
			pkg        := import_path[colon+1:]

			if path, has_collection := gv.collections[collection]; has_collection {
				import_path = filepath.join({gv.collections[collection], pkg})
			} else {
				error("Unknown collection %q", collection)
			}
		} else {
			import_path = filepath.join({gv.pkg.fullpath, import_path})
		}

		abs, found := filepath.abs(import_path)
		if !found {
			error("Could not get absolute path of %q", import_path)
		}

		if pkg, has_pkg := gv.graph.packages[import_path]; has_pkg {
			if pkg.name != "builtin" && pkg.name != "runtime" && pkg.name != "intrinsics" && !slice.contains(gv.gpkg.imports[:], pkg) {
				append(&gv.gpkg.imports, pkg)
			}
		} else {

			npkg := new(Package)
			npkg.fullpath = import_path

			append(&gv.gpkg.imports, npkg)

			gv.graph.packages[import_path] = npkg
			
			prev_ast_pkg := gv.pkg
			prev_pkg     := gv.gpkg

			gv.gpkg = npkg
			defer {
				gv.gpkg = prev_pkg
				gv.pkg  = prev_ast_pkg
			}
			
			parse_ok: bool
			gv.pkg, parse_ok = parser.parse_package_from_path(import_path)
			if !parse_ok {
				error("Parsing package %q failed", import_path)
			}

			npkg.name = gv.pkg.name

			ast.walk(v, gv.pkg)
		}
	}
	return nil
}

error :: proc(msg: string, args: ..any) -> ! {
	fmt.eprint("ERROR: ")
	fmt.eprintf(msg, ..args)
	fmt.eprintln()
	os.exit(1)
}
