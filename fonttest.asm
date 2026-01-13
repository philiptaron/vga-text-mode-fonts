; fonttest.asm - Tiny boot sector to display VGA font test pattern
; Assemble with: nasm -f bin fonttest.asm -o fonttest.bin

[BITS 16]
[ORG 0x7C00]

start:
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00

    ; Set video mode 3 (80x25 text)
    mov ax, 0x0003
    int 0x10

    ; Hide cursor
    mov ah, 0x01
    mov cx, 0x2607
    int 0x10

    ; Print test strings
    mov si, str1
    call print
    mov si, str2
    call print
    mov si, str3
    call print
    mov si, str4
    call print

    ; Print all 256 characters in a grid
    mov dh, 8           ; Start at row 8
    xor bl, bl          ; Character 0
.charloop:
    mov ah, 0x02        ; Set cursor
    xor bh, bh
    mov dl, 4           ; Column
    int 0x10

    mov cx, 16          ; 16 chars per row
.rowloop:
    mov al, bl
    mov ah, 0x0E        ; Teletype
    int 0x10
    mov al, ' '
    int 0x10
    inc bl
    loop .rowloop

    inc dh
    cmp bl, 0
    jnz .charloop

    ; Halt
    cli
.halt:  hlt
    jmp .halt

print:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0E
    int 0x10
    jmp print
.done:  ret

str1: db 13,10,"  ABCDEFGHIJKLMNOPQRSTUVWXYZ",13,10,0
str2: db "  abcdefghijklmnopqrstuvwxyz",13,10,0
str3: db "  0123456789 !@#$%^&*()",13,10,0
str4: db "  The quick brown fox jumps over the lazy dog",13,10,13,10,0

times 510-($-$$) db 0
dw 0xAA55
