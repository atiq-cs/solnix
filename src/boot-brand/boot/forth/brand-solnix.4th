\ solnix loader brand: "Solnix" with the solnix logo to its right.
\ brand.4th includes /boot/forth/brand-${loader_brand}.4th; /boot/conf.d/solnix-brand
\ sets loader_brand="solnix". The stock brand-illumos.4th and the "powered by illumos"
\ logo (logo-illumos.4th) are left as shipped.
\ The framebuffer path draws /boot/solnix-brand.png (src/boot-brand/art.nix) in the same
\ box as the stock wordmark: 7 text rows tall, width by aspect. The text fallback spells
\ Solnix in figlet "standard" (5 rows x 33 columns; the stock fallback is 39).
\
\ Derived from illumos' brand-illumos.4th (FreeBSD loader, Devin Teske,
\ BSD-2-Clause). Only the artwork + image path changed.

2 brandX ! 1 brandY ! \ Initialize brand placement defaults

: brand+ ( x y c-addr/u -- x y' )
	2swap 2dup at-xy 2swap \ position the cursor
	type \ print to the screen
	1+ \ increase y for next time we're called
;

: brand ( x y -- ) \ "Solnix" + logo (5 rows x 33 columns in text)

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

	s"  ____          _         _       " brand+
	s" / ___|   ___  | | _ __  (_)__  __" brand+
	s" \___ \  / _ \ | || '_ \ | |\ \/ /" brand+
	s"  ___) || (_) || || | | || | >  < " brand+
	s" |____/  \___/ |_||_| |_||_|/_/\_\" brand+

	2drop
;
