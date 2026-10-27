#!/usr/bin/env python3
# Generate build/if_iwm_illumos.c from upstream/if_iwm.c by exact,
# count-checked text replacement (each needle must match exactly once), then
# refresh patches/if_iwm.illumos.patch from the result. The patch is the
# reviewable delta; this script is how it is (re)made without patch(1),
# which dixi lacks.
import os, subprocess, sys
here = os.path.dirname(os.path.abspath(__file__))
src = open(os.path.join(here, 'upstream/if_iwm.c')).read()
R = []
def rep(old, new, count=1):
    n = src.count(old)
    if n != count:
        sys.exit("needle matched %d times (want %d): %r" % (n, count, old[:70]))
    R.append((old, new))
rep('''	m = m_gethdr(M_DONTWAIT, MT_DATA);
	if (m == NULL)
		return ENOBUFS;

	if (size <= MCLBYTES) {
		MCLGET(m, M_DONTWAIT);
	} else {
		MCLGETL(m, M_DONTWAIT, IWM_RBUF_SIZE);
	}
	if ((m->m_flags & M_EXT) == 0) {
		m_freem(m);
		return ENOBUFS;
	}
''', '''	/*
	 * ILLUMOS: m_gethdr + MCLGET/MCLGETL + the (m_flags & M_EXT) test all
	 * collapse into one allocation. This buffer is DMA'd and its RX
	 * descriptor stores a single address (dm_segs[0].ds_addr), so it must be
	 * physically contiguous and bind as one cookie; allocb()'s 4 KiB buffers
	 * can straddle a page and bind as two, which failed the nsegs == 1 map
	 * with EFBIG and lost the RX ring. iwm_dma_mblk_alloc() returns an mblk
	 * backed by DDI-contiguous memory, and opens the whole buffer as the
	 * write window, which is what "m->m_len = m->m_pkthdr.len =
	 * m->m_ext.ext_size" did.
	 */
	m = iwm_dma_mblk_alloc(sc->sc_dmat,
	    size <= MCLBYTES ? MCLBYTES : IWM_RBUF_SIZE);
	if (m == NULL)
		return ENOBUFS;
''')
rep('''	m->m_len = m->m_pkthdr.len = m->m_ext.ext_size;
	err = bus_dmamap_load_mbuf''', '''	err = bus_dmamap_load_mbuf''')
rep('''	m->m_data = pktdata + sizeof(*rx_res);
	m->m_pkthdr.len = m->m_len = len;
''', '''	/*
	 * ILLUMOS: "m->m_data = pktdata + sizeof(*rx_res); m->m_pkthdr.len =
	 * m->m_len = len" becomes one checked window move. len came from the
	 * DEVICE, so the bounds check is not theoretical.
	 */
	if (!iwx_m_set_window(m, pktdata + sizeof(*rx_res), len)) {
		IC2IFP(ic)->if_ierrors++;
		m_freem(m);
		return;
	}
''')
rep('''	m->m_data = pktdata + sizeof(*desc);
	m->m_pkthdr.len = m->m_len = len;
''', '''	/* ILLUMOS: checked window move, as in iwm_rx_mpdu above. */
	if (!iwx_m_set_window(m, pktdata + sizeof(*desc), len)) {
		IC2IFP(ic)->if_ierrors++;
		m_freem(m);
		return;
	}
''')
rep('''		memmove(m->m_data + 2, m->m_data, hdrlen);
		m_adj(m, 2);
''', '''		/*
		 * ILLUMOS: the memmove needs 2 + hdrlen bytes of cluster from
		 * b_rptr and the frame gets 2 bytes longer, so the write pointer
		 * must move with it; both are inside iwx_m_shift_right(). A
		 * failure means the device reported a header longer than the
		 * buffer it sent.
		 */
		if (!iwx_m_shift_right(m, hdrlen, 2)) {
			IC2IFP(ic)->if_ierrors++;
			m_freem(m);
			return;
		}
		m_adj(m, 2);
''')
rep('''		    m->m_len >= sizeof(struct ieee80211_qosframe_addr4)) {''',
    '''		    iwx_m_len(m) >= sizeof(struct ieee80211_qosframe_addr4)) {''')
rep('''		    m->m_len >= sizeof(struct ieee80211_qosframe)) {''',
    '''		    iwx_m_len(m) >= sizeof(struct ieee80211_qosframe)) {''')
rep('''		m = MCLGETL(NULL, M_DONTWAIT, totlen);''',
    '''		/*
		 * ILLUMOS: MCLGETL(NULL, ...) is an allocation, but this buffer
		 * is DMA'd below (bus_dmamap_load) and its TX descriptor stores a
		 * single address with num_tbs = 1, so it must be contiguous and
		 * single-cookie -- the same reason as the RX refill. allocb() does
		 * not promise that; iwm_dma_mblk_alloc() does.
		 */
		m = iwm_dma_mblk_alloc(sc->sc_dmat, totlen);''')
rep('''	totlen = m->m_pkthdr.len;

	if (ic->ic_opmode''', '''	totlen = iwx_m_pktlen(m);	/* ILLUMOS: m->m_pkthdr.len */

	if (ic->ic_opmode''')
rep('''			totlen = m->m_pkthdr.len;
			k = NULL;''', '''			totlen = iwx_m_pktlen(m);	/* ILLUMOS */
			k = NULL;''')
rep('''		/* Too many DMA segments, linearize mbuf. */
		if (m_defrag(m, M_DONTWAIT)) {
			m_freem(m);
			return ENOBUFS;
		}
''', '''		/*
		 * Too many DMA segments, linearize mbuf.
		 *
		 * ILLUMOS: the head can MOVE. m_defrag() rewrites m in place;
		 * msgpullup() returns a new head and consumes the old one, so m
		 * must be reassigned or data->m = m below dangles.
		 * iwx_m_defrag() frees the original on failure.
		 */
		if ((m = iwx_m_defrag(m)) == NULL)
			return ENOBUFS;
''')
rep('''			ni = m->m_pkthdr.ph_cookie;''', '''			/*
			 * ILLUMOS: m_pkthdr.ph_cookie rides in b_prev for the
			 * enqueue->dequeue window on ic_mgtq only and is cleared
			 * as it is read (see ../iwx/iwx_mcookie.h).
			 */
			ni = iwx_m_take_cookie(m);''')
rep('''		if (m->m_len < sizeof (*eh) &&''', '''		if (iwx_m_len(m) < sizeof (*eh) &&	/* ILLUMOS: m->m_len */''')
rep('''		pkt = (struct iwm_rx_packet *)(m0->m_data + offset);
''', '''		/*
		 * ILLUMOS: m0->m_data + offset. offset advances by a length the
		 * DEVICE reported, so the step is bounds checked.
		 */
		pkt = iwx_m_at(m0, offset, minsz);
		if (pkt == NULL)
			break;
''')
rep('''			nextpkt = (struct iwm_rx_packet *)
			    (m0->m_data + nextoff);
			if (nextoff + minsz >= IWM_RBUF_SIZE ||
''', '''			nextpkt = iwx_m_at(m0, nextoff, minsz);
			if (nextoff + minsz >= IWM_RBUF_SIZE ||
			    nextpkt == NULL ||		/* ILLUMOS: bounds */
''')
rep('''				m = m_copym(m0, 0, M_COPYALL, M_DONTWAIT);''',
    '''				m = iwx_m_copy(m0);	/* ILLUMOS: m_copym */''')
# ILLUMOS double-free fix: iwm_free_rx_ring is called twice on the attach error
# path -- once at iwm_alloc_rx_ring's own `fail:`, then again by iwm_attach's
# cleanup. OpenBSD's bus_dmamap_destroy tolerates a second call; illumos'
# ddi_dma_free_handle does not (it mutex_destroy()s an already-freed handle ->
# "mutex_destroy: bad mutex" panic, root-caused from a dixi crash dump). NULL the
# per-buffer map after destroying it so the second pass is a no-op. The contig
# frees above are already idempotent (iwm_dma_contig_free NULLs dma->map).
rep("""		if (data->map != NULL)
			bus_dmamap_destroy(sc->sc_dmat, data->map);
	}
}""",
    """		if (data->map != NULL) {
			bus_dmamap_destroy(sc->sc_dmat, data->map);
			data->map = NULL;	/* ILLUMOS: free_{rx,tx}_ring runs twice on the error path */
		}
	}
}""", count=2)

# ILLUMOS: on the AC 9560 (9000 fw 46.x) with MSI (not MSI-X) under the giant
# model, enabling device-level dynamic power save parks the firmware the moment
# the aggressive-assoc time event expires (~2 x beacon interval), before the
# AUTH/ASSOC exchange completes: measured on dixi via DTrace -- interrupts and
# RX stop ~200 ms after iwm_protect_session and the AP's auth response is never
# received, so association never advances past AUTH. Keep device PS off so the
# firmware stays on the BSS channel through the full auth/assoc/4-way exchange.
# A focused divergence from OpenBSD (which does not hit this on its own
# interrupt/scheduling model); revisit if a later firmware or an MSI-X path
# removes the need.
rep("""	if (ic->ic_opmode != IEEE80211_M_MONITOR)
		cmd.flags = htole16(IWM_DEVICE_POWER_FLAGS_POWER_SAVE_ENA_MSK);

	return iwm_send_cmd_pdu(sc,
	    IWM_POWER_TABLE_CMD, 0, sizeof(cmd), &cmd);""",
    """	/*
	 * ILLUMOS: do NOT set IWM_DEVICE_POWER_FLAGS_POWER_SAVE_ENA_MSK. On the
	 * 9000 family with MSI under the giant model, device PS parks the
	 * firmware at time-event expiry before association completes; see
	 * gen-illumos-src.py for the DTrace evidence.
	 */
	return iwm_send_cmd_pdu(sc,
	    IWM_POWER_TABLE_CMD, 0, sizeof(cmd), &cmd);""")


rep('\tif (in->in_ni.ni_intval)\n\t\tduration = in->in_ni.ni_intval * 2;\n\telse\n\t\tduration = IEEE80211_DUR_TU; \n\tiwm_protect_session(sc, in, duration, in->in_ni.ni_intval / 2);',
    "\t/*\n\t * ILLUMOS: hold the firmware on the BSS channel through the WHOLE\n\t * auth + assoc + 4-way exchange. Measured on dixi (DTrace): with the\n\t * stock ~200ms (2 x beacon interval) aggressive-assoc time event the\n\t * fw stops delivering RX/interrupts right after the auth commands and\n\t * the AP auth response is never received, so association never leaves\n\t * AUTH. Under our giant-lock + deferred-task model the exchange takes\n\t * longer than OpenBSD's, so (a) clear any stale IWM_FLAG_TE_ACTIVE so a\n\t * fresh TE is armed on every attempt (the TE-end notification that\n\t * would clear it arrives via an interrupt that stops once the fw goes\n\t * quiet), and (b) request a much longer duration.\n\t */\n\tsc->sc_flags &= ~IWM_FLAG_TE_ACTIVE;\n\tif (in->in_ni.ni_intval)\n\t\tduration = in->in_ni.ni_intval * 25;\n\telse\n\t\tduration = IEEE80211_DUR_TU * 25;\n\tiwm_protect_session(sc, in, duration, in->in_ni.ni_intval / 2);")


# rep() has already asserted each needle's exact count; replace all of them.
# solnix: OpenBSD continues the autoconf attach line here; on illumos it is a stray
# console line (", msi"). The interrupt type is in prtconf/intrstat.
rep('''	printf(", %s\\n", intrstr);''', '''	(void) intrstr;	/* solnix: no stray ", msi" console line */''')
# solnix: the firmware/MAC line goes to the system log only (cmn_err "!"), not the console.
rep('''	printf("%s: hw rev 0x%x, fw ver %s, address %s\\n",''', '''	cmn_err(CE_CONT, "!%s: hw rev 0x%x, fw ver %s, address %s\\n",''')

for o, n in R:
    src = src.replace(o, n)
os.makedirs(os.path.join(here, 'build'), exist_ok=True)
out = os.path.join(here, 'build/if_iwm_illumos.c')
open(out, 'w').write(src)
d = subprocess.run(['diff', '-u', os.path.join(here, 'upstream/if_iwm.c'), out],
                   capture_output=True, text=True).stdout.split('\n')
d[0:2] = ['--- a/if_iwm.c', '+++ b/if_iwm.c']
hunks = sum(1 for l in d if l.startswith('@@'))
if hunks == 0:
    sys.exit('generated source equals the vendored one: refusing a no-op patch')
open(os.path.join(here, 'patches/if_iwm.illumos.patch'), 'w').write('\n'.join(d))
print('applied', len(R), 'replacements;', hunks, 'hunks in patches/if_iwm.illumos.patch')
