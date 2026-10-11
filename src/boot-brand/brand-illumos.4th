\ solnix loader brand: "Solnix" in the figlet standard font, with a small
\ flame glyph to the left of the S (nodding to the phoenix logo at right).
\ Replaces the stock brand-illumos.4th. The framebuffer path points at the
\ solnix brand PNG; the text fallback spells Solnix.
\
\ Derived from illumos' brand-illumos.4th (FreeBSD loader, Devin Teske,
\ BSD-2-Clause). Only the artwork + image path changed.

2 brandX ! 1 brandY ! \ Initialize brand placement defaults

: brand+ ( x y c-addr/u -- x y' )
	2swap 2dup at-xy 2swap \ position the cursor
	type \ print to the screen
	1+ \ increase y for next time we're called
;

: brand ( x y -- ) \ "Solnix" with a flame glyph left of the S (5 rows)

	framebuffer? if
		s" term-putimage" sfind if
			\ 0,0 upper-left origin; 0,7 lower-right to keep aspect
			>r 0 0 0 0 7
			s" /boot/solnix-brand.png"
			r> execute if 2drop exit then
		else
			drop
		then
	then

	\ flame glyph (left) + "Solnix" in figlet "standard" (5 rows x 46 cols)
	s"    )    ____         _         _       " brand+
	s"   ( /   / ___|  ___ | | _ __  (_)__  __" brand+
	s"    )(   \___ \ / _ \| || '_ \ | |\ \/ /" brand+
	s"   ( /    ___) | (_) | || | | || | >  < " brand+
	s"    V    |____/ \___/|_||_| |_||_|/_/\_\" brand+

	2drop
;
