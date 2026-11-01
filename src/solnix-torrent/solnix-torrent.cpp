// solnix-torrent -- the libtorrent-rasterbar (BSD-3) front end for the solnix cache proxy and seeder.
//   solnix-torrent fetch <torrent-url-or-file> <out> <seconds>   download the single-file NAR into <out>, or exit 1
//   solnix-torrent seed <dir> <nar>...                            make each NAR's torrent and seed them all until killed
//   solnix-torrent infohash <nar>                                 print the deterministic v1 infohash (the self-check)
//   solnix-torrent probe <torrent-url-or-file>                    swarm health: exit 0 iff the tracker lists a seed and
//                                                                 at least one PUBLIC peer for it (not RFC1918/loopback)
// Conventions (infra 2026-10-28): 256 KiB pieces, name = NAR basename, no creation date or creator (so the infohash
// depends on the NAR bytes alone), the single public tracker, no DHT, no PEX, no LSD, no UPnP/NAT-PMP. The announce
// URL in a fetched .torrent is ignored: only the info dict (the infohash) is used, and announces go to TRACKER.
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/torrent_flags.hpp>
#include <libtorrent/bdecode.hpp>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <thread>
#include <unistd.h>
#include <vector>
namespace lt = libtorrent;
static const char *TRACKER = getenv("SOLNIX_TORRENT_TRACKER") ? getenv("SOLNIX_TORRENT_TRACKER") : "https://tracker.solnix.io/announce";	// override: tests only
static std::string hex(const lt::sha1_hash &h) {	// not lt::aux::to_hex: that is internal API (hidden at ABI 3)
	static const char d[] = "0123456789abcdef"; std::string r;
	for (int i = 0; i < int(h.size()); i++) { unsigned char c = (unsigned char)h.data()[i]; r += d[c >> 4]; r += d[c & 15]; }
	return r;
}

static lt::settings_pack pack() {
	lt::settings_pack p;
	p.set_bool(lt::settings_pack::enable_dht, false);
	p.set_bool(lt::settings_pack::enable_lsd, false);
	p.set_bool(lt::settings_pack::enable_upnp, false);
	p.set_bool(lt::settings_pack::enable_natpmp, false);
	// TCP only: on illumos every uTP connect timed out (measured 2026-10-28, OI host, loopback), eating the fetch window
	p.set_bool(lt::settings_pack::enable_outgoing_utp, false);
	p.set_bool(lt::settings_pack::enable_incoming_utp, false);
	// peers behind one address (a NAT, or two peers on one host) are distinct peers: without this libtorrent kept only
	// the first 127.0.0.1 candidate (itself) and dropped the seeder as a duplicate (measured)
	p.set_bool(lt::settings_pack::allow_multiple_connections_per_ip, true);
	p.set_int(lt::settings_pack::alert_mask, getenv("SOLNIX_TORRENT_DEBUG") ? lt::alert_category::all
	          : lt::alert_category::error | lt::alert_category::status);
	if (const char *l = getenv("SOLNIX_TORRENT_LISTEN")) p.set_str(lt::settings_pack::listen_interfaces, l);
	return p;
}
static std::shared_ptr<lt::torrent_info> make(const std::string &nar, lt::error_code &ec) {
	lt::file_storage fs;
	lt::add_files(fs, nar);
	if (fs.num_files() != 1) {	// add_files on a missing path adds nothing
		std::cerr << "solnix-torrent: " << nar << ": " << fs.num_files() << " files\n";
		ec = lt::errors::make_error_code(lt::errors::invalid_torrent_handle); return nullptr;
	}
	lt::create_torrent ct(fs, 256 * 1024, lt::create_torrent::v1_only);
	std::string dir = nar.substr(0, nar.rfind('/') == std::string::npos ? 0 : nar.rfind('/'));
	lt::set_piece_hashes(ct, dir.empty() ? "." : dir, ec);
	if (ec) return nullptr;
	ct.add_tracker(TRACKER);
	std::vector<char> buf; lt::bencode(std::back_inserter(buf), ct.generate());
	return std::make_shared<lt::torrent_info>(buf, ec, lt::from_span);
}
static lt::add_torrent_params params(std::shared_ptr<lt::torrent_info> ti, const std::string &save) {
	// only our tracker: a .torrent's own announce list is dropped (measured: libtorrent tried the served torrents'
	// cluster-internal tracker.torrent.svc.cluster.local first and never reached the public one)
	ti->clear_trackers();
	lt::add_torrent_params a; a.ti = ti; a.save_path = save; a.trackers = {TRACKER};
	// default_flags = update_subscribe | auto_managed | paused | apply_ip_filter | need_save_resume: clear both
	// auto_managed and paused, or the torrent is "force stopped" and never announces
	a.flags &= ~(lt::torrent_flags::auto_managed | lt::torrent_flags::paused); a.flags |= lt::torrent_flags::disable_dht | lt::torrent_flags::disable_pex | lt::torrent_flags::disable_lsd;
	return a;
}

static bool curl(const std::string &url, const std::string &to) {	// no shell quoting games: refuse a quote
	if (url.find('\'') != std::string::npos || to.find('\'') != std::string::npos) return false;
	return system(("curl -sS -m 10 -f -o '" + to + "' '" + url + "'").c_str()) == 0;
}
static std::shared_ptr<lt::torrent_info> load(const std::string &src, const std::string &tmp) {
	lt::error_code ec; std::shared_ptr<lt::torrent_info> ti;
	if (src.rfind("http", 0) == 0) {	// the proxy passes the Torrent: URL; curl fetches it to a temp file first
		if (!curl(src, tmp)) return nullptr;
		ti = std::make_shared<lt::torrent_info>(tmp, ec); std::remove(tmp.c_str());
	} else ti = std::make_shared<lt::torrent_info>(src, ec);
	if (ec || ti->num_files() != 1) { std::cerr << "solnix-torrent: bad torrent " << ec.message() << "\n"; return nullptr; }
	return ti;
}
// probe: one announce of our own (curl, compact, left = size, so the tracker answers as to a leecher), then event=stopped.
// Peers in 0/8 10/8 100.64/10 127/8 169.254/16 172.16/12 192.168/16 cannot be reached from another host, so they do
// not count: today tracker.solnix.io lists every peer as its ingress pod 10.42.0.158 (measured 2026-10-29).
// shortcut: IPv4 compact peers only (the tracker sends no peers6 today); add peers6 when it does.
static bool unreachable(const unsigned char *a) {
	return a[0] == 0 || a[0] == 10 || a[0] == 127 || (a[0] == 100 && (a[1] & 0xc0) == 64) || (a[0] == 169 && a[1] == 254)
	    || (a[0] == 172 && (a[1] & 0xf0) == 16) || (a[0] == 192 && a[1] == 168);
}
static int probe(const std::string &src) {
	std::string tmp = "/tmp/solnix-torrent-probe." + std::to_string(getpid());
	auto ti = load(src, tmp); if (!ti) { std::cout << "down: no torrent\n"; return 1; }
	lt::sha1_hash ih = ti->info_hashes().v1; std::string q = "?info_hash=";
	for (int i = 0; i < 20; i++) { char b[4]; std::snprintf(b, sizeof b, "%%%02X", (unsigned char)ih.data()[i]); q += b; }
	// port=1: our own entry in the reply is told apart from real peers by it (no BitTorrent peer listens on 1)
	q += "&peer_id=-SX0001-" + hex(ih).substr(0, 12) + "&port=1&uploaded=0&downloaded=0&compact=1&numwant=50&left="
	     + std::to_string(ti->total_size());
	bool got = curl(std::string(TRACKER) + q, tmp);
	curl(std::string(TRACKER) + q + "&event=stopped", tmp + ".s"); std::remove((tmp + ".s").c_str());
	std::ifstream f(tmp, std::ios::binary); std::vector<char> b((std::istreambuf_iterator<char>(f)), {}); std::remove(tmp.c_str());
	lt::error_code ec; lt::bdecode_node n = got ? lt::bdecode(b, ec) : lt::bdecode_node();
	if (!got || ec || n.type() != lt::bdecode_node::dict_t) { std::cout << "down: no tracker reply\n"; return 1; }
	if (n.dict_find_string("failure reason")) { std::cout << "down: tracker: " << n.dict_find_string_value("failure reason") << "\n"; return 1; }
	auto p = n.dict_find_string_value("peers"); int pub = 0, priv = 0;
	for (std::size_t i = 0; i + 6 <= p.size(); i += 6) {
		const unsigned char *e = (const unsigned char *)p.data() + i;
		if (e[4] == 0 && e[5] == 1) continue;	// ourselves
		(unreachable(e) ? priv : pub)++;
	}
	std::int64_t seeds = n.dict_find_int_value("complete", -1);
	std::cout << (pub && seeds > 0 ? "ok" : "down") << ": " << pub << " public peers, " << priv << " private/loopback, complete "
	          << seeds << "\n";
	return pub && seeds > 0 ? 0 : 1;
}

static int fetch(const std::string &src, const std::string &out, int secs) {
	lt::error_code ec; std::shared_ptr<lt::torrent_info> ti = load(src, out + ".torrent");
	if (!ti) return 1;
	std::string dir = out + ".d"; lt::session s{lt::session_params{pack()}};
	lt::torrent_handle h = s.add_torrent(params(ti, dir), ec);
	if (ec) return 1;
	// give up early when nothing arrives: SOLNIX_TORRENT_STALL (10) s without one new payload byte
	int stall = getenv("SOLNIX_TORRENT_STALL") ? atoi(getenv("SOLNIX_TORRENT_STALL")) : 10;
	auto now = [] { return std::chrono::steady_clock::now(); };
	auto end = now() + std::chrono::seconds(secs), moved = now();
	std::int64_t seen = 0;
	while (now() < end && now() - moved < std::chrono::seconds(stall)) {
		std::this_thread::sleep_for(std::chrono::milliseconds(250));
		if (getenv("SOLNIX_TORRENT_DEBUG")) { std::vector<lt::alert *> al; s.pop_alerts(&al); for (auto *x : al) std::cerr << "  " << x->message() << "\n"; }
		lt::torrent_status st = h.status();
		if (st.total_payload_download > seen) { seen = st.total_payload_download; moved = now(); }
		if (st.is_seeding) {	// libtorrent checked every piece hash against the info dict
			std::string f = dir + "/" + ti->files().file_path(lt::file_index_t(0));
			s.remove_torrent(h); std::this_thread::sleep_for(std::chrono::milliseconds(200));
			if (std::rename(f.c_str(), out.c_str()) != 0) return 1;
			std::remove(dir.c_str()); return 0;
		}
	}
	lt::torrent_status st = h.status();
	s.remove_torrent(h, lt::session::delete_files); std::this_thread::sleep_for(std::chrono::milliseconds(200));
	std::remove((dir + "/" + ti->files().file_path(lt::file_index_t(0))).c_str()); std::remove(dir.c_str());	// no partial bytes left behind
	std::cerr << "solnix-torrent: no complete copy from the swarm (window " << secs << " s, stall " << stall << " s; got "
	          << st.total_payload_download << " B, " << st.total_failed_bytes << " B failed the piece hash; peers " << st.num_peers
	          << ", seeds " << st.num_seeds << ", " << int(st.progress * 100) << "%, state " << int(st.state) << ")\n";
	return 1;
}
static int seed(const std::string &dir, int argc, char **argv) {
	lt::session s{lt::session_params{pack()}}; lt::error_code ec; int n = 0;
	for (int i = 0; i < argc; i++) {
		std::string nar = dir + "/" + argv[i];
		// test hook: seed <dir>'s bytes under the infohash of SOLNIX_TORRENT_SEED_AS/<nar> (a lying peer)
		const char *as = getenv("SOLNIX_TORRENT_SEED_AS");
		auto ti = make(as ? std::string(as) + "/" + argv[i] : nar, ec);
		if (!ti) { std::cerr << "solnix-torrent: skip " << argv[i] << ": " << ec.message() << "\n"; continue; }
		lt::add_torrent_params a = params(ti, dir); a.flags |= lt::torrent_flags::seed_mode;
		s.add_torrent(a, ec); if (!ec) { n++; std::cout << hex(ti->info_hashes().v1) << " " << argv[i] << "\n"; }
	}
	std::cout.flush(); if (!n) return 1;
	for (;;) {	// alerts to the SMF log; the seeder restarts us when its list changes
		std::vector<lt::alert *> al; s.wait_for_alert(std::chrono::seconds(60)); s.pop_alerts(&al);
		for (lt::alert *x : al)
			if (getenv("SOLNIX_TORRENT_DEBUG") || (x->category() & lt::alert_category::error)) std::cerr << x->message() << "\n";
		std::cerr.flush();
	}
}
int main(int argc, char **argv) {
	if (argc == 5 && !strcmp(argv[1], "fetch")) return fetch(argv[2], argv[3], atoi(argv[4]));
	if (argc >= 4 && !strcmp(argv[1], "seed")) return seed(argv[2], argc - 3, argv + 3);
	if (argc == 3 && !strcmp(argv[1], "probe")) return probe(argv[2]);
	if (argc == 3 && !strcmp(argv[1], "infohash")) {
		lt::error_code ec; auto ti = make(argv[2], ec);
		if (!ti) { std::cerr << ec.message() << "\n"; return 1; }
		std::cout << hex(ti->info_hashes().v1) << "\n"; return 0;
	}
	std::cerr << "usage: solnix-torrent fetch <torrent-url|file> <out> <seconds> | seed <dir> <nar>... | infohash <nar> | probe <torrent-url|file>\n";
	return 2;
}
