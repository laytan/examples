; Some of the following assembly code is taken from LuaCoco by Mike Pall.
; See https://coco.luajit.org/index.html
; 
; MIT license
; 
; Copyright (C) 2004-2016 Mike Pall. All rights reserved.
; 
; Permission is hereby granted, free of charge, to any person obtaining
; a copy of this software and associated documentation files (the
; "Software"), to deal in the Software without restriction, including
; without limitation the rights to use, copy, modify, merge, publish,
; distribute, sublicense, and/or sell copies of the Software, and to
; permit persons to whom the Software is furnished to do so, subject to
; the following conditions:
; 
; The above copyright notice and this permission notice shall be
; included in all copies or substantial portions of the Software.
; 
; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
; IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
; CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
; TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
; SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
section .text

global _mco_switch
_mco_switch: ; proc(from, to: ^_ctxbuf, ^runtime.Context)
    lea rax, [rel .resume_point] ; Get resume point.
    mov [rdi], rax ; Store resume point into `from.rsp`.

    ; Store context.
    mov [rdi + 8], rsp
    mov [rdi + 16], rbp
    mov [rdi + 24], rbx
    mov [rdi + 32], r12
    mov [rdi + 40], r13
    mov [rdi + 48], r14
    mov [rdi + 56], r15

    ; Set context to target values.
    mov r15, [rsi + 56]
    mov r14, [rsi + 48]
    mov r13, [rsi + 40]
    mov r12, [rsi + 32]
    mov rbx, [rsi + 24]
    mov rbp, [rsi + 16]
    mov rsp, [rsi + 8]

    mov rax, [rsi] ; Move target jump address from rsi (2nd arg) (`to.rsp`) into rax.
    mov rsi, rdx   ; Move the ^Context from rdx (3rd arg) into rsi (2nd arg), which _main will expect.

    jmp rax ; Jump to the target jump address.
.resume_point: ; Resume lands at this point.
    ret

global _mco_wrap_main
_mco_wrap_main:
    mov rdi, r13
    jmp r12
