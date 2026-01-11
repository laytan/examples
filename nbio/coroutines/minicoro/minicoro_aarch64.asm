/*
vim: syntax=armasm nospell

Some of the following assembly code is taken from LuaCoco by Mike Pall.
See https://coco.luajit.org/index.html

MIT license

Copyright (C) 2004-2016 Mike Pall. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*/
    .text
	.section __TEXT,__text

.global __mco_switch
__mco_switch: ; proc(from, to: ^_ctxbuf, ^runtime.Context)
    mov x10, sp  ; Save stack pointer into x10
    mov x11, x30 ; Safe return address into x11

    ; Store current register values into the first argument `from`.
    stp x19, x20, [x0, #(0*16)]
    stp x21, x22, [x0, #(1*16)]
    stp d8, d9,   [x0, #(7*16)]
    stp x23, x24, [x0, #(2*16)]
    stp d10, d11, [x0, #(8*16)]
    stp x25, x26, [x0, #(3*16)]
    stp d12, d13, [x0, #(9*16)]
    stp x27, x28, [x0, #(4*16)]
    stp d14, d15, [x0, #(10*16)]
    stp x29, x30, [x0, #(5*16)]

    ; Store stored stack pointer and link register into first argument `from`.
    stp x10, x11, [x0, #(6*16)]

    ; Load register values from the second argument `to`.
    ldp x19, x20, [x1, #(0*16)]
    ldp x21, x22, [x1, #(1*16)]
    ldp d8, d9,   [x1, #(7*16)]
    ldp x23, x24, [x1, #(2*16)]
    ldp d10, d11, [x1, #(8*16)]
    ldp x25, x26, [x1, #(3*16)]
    ldp d12, d13, [x1, #(9*16)]
    ldp x27, x28, [x1, #(4*16)]
    ldp d14, d15, [x1, #(10*16)]
    ldp x29, x30, [x1, #(5*16)]

    ; Load stack pointer and link register from the second argument `to`.
    ldp x10, x11, [x1, #(6*16)]

    mov x1, x2 ; Move the `context` from the third argument register to the second argument register, intended for the `_main` call later.

    mov sp, x10 ; Set stack pointer to the one that was stored in the second argument `to`.
    br x11      ; Return to saved link register (return address)

.global __mco_wrap_main
__mco_wrap_main: ; proc(_, ^runtime.Context)
    mov x0, x19  ; Take coroutine out of x19 (x[0]) and store into x0 (first argument).
    mov x30, x21 ; Take the return address out of x21 (x[3]) and store into x30 (link register).
    br x20       ; Call the `_main(^Coro, ^runtime.Context)` function.
