;--------------------------------------
;
;	The WOZ Monitor for IBM PC
;	Original written by Steve Wozniak 1976
;	8086 rewrite by Jarrod Kunter 2024
;
;	Based off the 6502 source code from
;	https://www.sbprojects.net/projects/apple1/wozmon.php
;
;
;	WOZMON in only 248 bytes!
;
;	To build:
;		nasm -f bin -o wozmon.img wozmon.asm
;
;	To run:
;		Use a virtual machine like Bochs or VirtualBox and use "wozmon.img" as a floppy disk image
;		Write "wozmon.img" to a floppy disk using something like DiskWrite https://freeextractor.sourceforge.net/diskwrite/
;
;--------------------------------------




; Set the CPU bits and type
bits 16
cpu 8086


; The starting address of the program in memory
; The IBM PC loads the boot sector to this address from disk
org 0x7c00

;--------------------------------------
; Register declarations
;--------------------------------------

; The original WOZMON used some zero page variables
; Since the 8086 has more registers, I just used those instead

; XAML		SI				The current examaine address
; XAMH						SI is a 16 bit register, so this is just the high byte of SI
; STL		DI				The current address to store at
; STH						DI is a 16 bit register, so this is just the high byte of DI
; L			CL				Low value of hex parsing
; H			CH				High value of hex parsing
; YSAV		DH				Saved value of the input buffer index
; MODE		DL				0=XAM, ':'=STOR, '.'=BLOCK XAM
;			BX				The current input buffer index

; IN						The input buffer. This is defined at the end of the file

; These declarations from the original WOZMON aren't needed here
; They deal with the keyboard and display, we just use BIOS interupts
;
; KBD
; KBDCR
; DSP
; DSPCR


;--------------------------------------
;	Constants
;--------------------------------------

BS		equ		0x08		; The backspace key
CR		equ		0x0d		; The return/enter key
ESC		equ		0x1b		; The escape key
PROMPT	equ		'\'			; Prompt character





;--------------------------------------
;	RESET is the first thing to run after POST
;	It puts the system into a known state for WOZMON execution
;--------------------------------------

_RESET:
	cld							; Clear the direction flag
	cli							; Make sure interrupts are disabled
	xor		ax,		ax
	mov		ss,		ax			; Setup the stack to above WOZMON
								; The original ran on the MOS 6502 processor
								; which had a fixed stack address, so it
								; excluded this step
	mov		sp,		_RESET
	mov		es,		ax			; Set the segment registers to the first 64K of ram
	mov		ds,		ax
	mov		bh,		al			; 
	mov		al,		ESC			; Set the current evaluated character to ESC and fall through to _NOTCR
								; The original had this already set from setting up the display

;--------------------------------------
;	The GETLINE process
;--------------------------------------

_NOTCR:
	cmp		al,		BS			; Check if backspace
	je		_BACKSPACE
	cmp		al,		ESC			; Check if escape (gets run after a RESET)
	je		_ESCAPE
	inc		bl					; Advance input buffer index
	jnz		_NEXTCHAR			; Auto ESC if line is longer than 255 (twice as long as original)

_ESCAPE:
	mov		al,		PROMPT		; Print the PROMPT character
	call	_ECHO

_GETLINE:
	mov		al,		CR			; New line
	call	_ECHO

	mov		bl,		1			; Reset input index (set to 1 so a fall through will set it to 0)
_BACKSPACE:
	dec		bl					; Decrements the input index
	js		_GETLINE			; If the input index underflows, just go to a new line

_NEXTCHAR:
	xor		ah,		ah
	int		0x16				; BIOS call for Get Keystroke. AL = ASCII character of key pressed
								; This call blocks until a key has been pressed
	mov		[_IN + bx],	al		; Add character to input buffer
	call	_ECHO				; Print the character
	cmp		al,		CR			; Check if it was a return/enter
	jne		_NOTCR				; If it wasn't, check if it was another special key

; Line received, now let's parse it

	mov		bl,		-1			; Set the input buffer index to the begining of the buffer
								; It's set to 1 less because it will get incremented below
	xor		ax,		ax			; Clear the AX register for later use

_SETSTOR:			
;	shl		al,		1			; This was not needed, but I left it here because it was in the original

_SETMODE:
	mov		dl,		al			; Set the mode to XAM

_BLSKIP:
	inc		bl					; Advance input buffer index

_NEXTITEM:
	mov		al,		[_IN + bx]	; Get the character from the input buffer
	cmp		al,		CR			; Check if its the end of the buffer
	je		_GETLINE			; Finished parsing the line
	cmp		al,		'.'			; Check for BLOCK XAM
	jb		_BLSKIP				; If the character was below the '.' character, ignore it
	je		_SETMODE			; If it was '.', set the mode to BLOCK XAM
	cmp		al,		':'			; Check for STOR
	je		_SETSTOR			; Set mode to STOR
	cmp		al,		'R'			; Check for RUN
	je		_RUN

; It wasn't a special character, it must be a hex value

	xor		cx,		cx			; Clear the hex parsing value
	mov		dh,		bl			; Save the input buffer index, just in case

; Hex value parsing

_NEXTHEX:
	mov		al,		[_IN + bx]	; Get the character from the input buffer
	xor		al,		0x30		; Convert value to check if its 0-9 (0x30-0x39)
	cmp		al,		9
	jbe		_DIG				; Check if digit
	add		al,		0x89		; Convert to see if it's a hex value (0xFA-0xFF)
	cmp		al,		0xfa
	jb		_NOTHEX				; If the value has overflowed, it will now be lower than 0xfa
								; and thus is not a valid hex value
; Convert from ascii to hex

_DIG:
	shl		al,		1			; Move the value to the top 4 bits of the register for the next step
	shl		al,		1
	shl		al,		1
	shl		al,		1

	mov		ah,		4			; The shift amount
_HEXSHIFT:
	shl		al,		1			; Shift the top bit into the carry flag
	rcl		cx,		1			; Shift the carry flag (the top bit of our hex value)
								; into the hex parsing value
	dec		ah					; Decrement the shift amount
	jnz		_HEXSHIFT			; Not done yet
	inc		bl					; Advance the input buffer index
	jmp		_NEXTHEX			; Get the next hex value

_NOTHEX:
	cmp		bl,		dh			; Check if we've parsed any characters
	je		_ESCAPE				; We have not. Drop back to prompt
	cmp		dl,		':'			; Check if we're in STOR mode
	jne		_NOTSTOR

;--------------------------------------
;	Store mode
;--------------------------------------

	mov		al,		cl			; Move the byte value we parsed to the address of DI
	stosb						; This stores the byte in AL into the address of DI and increments DI
_TONEXTITEM:
	jmp		_NEXTITEM			; This is here because a conditional branch below cannot reach _NEXTITEM

;--------------------------------------
;	Run mode
;--------------------------------------

_RUN:
	jmp		si					; Go to the address in SI

;--------------------------------------
;	Examine mode
;--------------------------------------

_NOTSTOR:
	cmp		dl,		'.'			; Check if the mode is BLOCK XAM
	je		_XAMNEXT

_SETADR:
	mov		di,		cx			; Copy the hex value to the Store address...
	mov		si,		cx			; ...and to the Examine address

	xor		al,		al			; This makes the next instruction fall through for printing the address
_NXTPRNT:
	jnz		_PRDATA				; Check if there's an address to print
	mov		al,		CR			; Print a new line
	call	_ECHO
	mov		ax,		si			; Copy the Examine address
	xchg	al,		ah			; Swap the High and Low bytes to get the upper byte in AL
	call	_PRBYTE				; Print the upper byte
	mov		ax,		si			; Copy the address again to print the lower byte
	call	_PRBYTE
	mov		al,		':'			; Print a colon
	call	_ECHO

_PRDATA:
	mov		al,		' '			; Print a space
	call	_ECHO
	mov		al,		[si]		; Print the value at the Examine address
	call	_PRBYTE

_XAMNEXT:
	xor		dl,		dl			; Set the mode to XAM
	cmp		si,		cx			; Check if we've reached the end address
								; (if not BLOCK XAM these will be the same)
	jae		_TONEXTITEM			; All done (This uses the above JMP to get further than JAE allows normally)
	inc		si					; Next address

_MOD8CHK:
	mov		ax,		si
	and		al,		0x07		; This is for printing only 8 values per line
	jmp		_NXTPRNT

;--------------------------------------
;	Print a byte as hex
;--------------------------------------

_PRBYTE:
	push	ax					; Save a copy of the value
	shr		al,		1			; Get the upper 4 bits
	shr		al,		1
	shr		al,		1
	shr		al,		1
	call	_PRHEX				; Print the upper 4 bits
	pop		ax					; Get the saved value to print the lower 4 bits

;--------------------------------------
;	Print a hex digit
;--------------------------------------

_PRHEX:
	and		al,		0x0f		; Get only the lower 4 bits
	add		al,		'0'			; Get the value to 0-9 in ASCII
	cmp		al,		'9'			; If the value is above 9, it's a hex digit
	jbe		_ECHO				; If it's not above just print it
	add		al,		7			; Otherwise add the difference A-9 to get to A-F

;--------------------------------------
;	Print a character to the screen
;--------------------------------------

_ECHO:
	push	ax					; Save the value to save on instruction elsewhere
	mov		ah,		0x0e		; Interrupt command Print to Terminal
	push	bx					; BX gets changed so we need to save it
	xor		bl,		bl			; Set the screen page to 0
	cmp		al,		CR			; Check if we are printing a New Line
	jne		.print_char			; If not just print the character
	int		0x10				; Print the CR (Cartridge Return)
	mov		al,		10			; Setup to print LF (Line Feed)
.print_char:
	int		0x10				; Print the character
	pop		bx					; Restore BX
	pop		ax					; Restore the saved value
	ret

;--------------------------------------
;	The input buffer.
;--------------------------------------

_IN:


;--------------------------------------
;	Disk Sector Padding
;--------------------------------------

; Pad the rest of the sector
db (512-2)-($-_RESET) dup(0)

; The magic boot values
db 0x55, 0xaa

