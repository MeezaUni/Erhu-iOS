package main

import (
	"net"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
)

// lanAddresses lists this computer's addresses on the local network, the most likely one first.
func lanAddresses() []string {
	var out []string
	add := func(ip net.IP) {
		v4 := ip.To4()
		if v4 == nil || v4.IsLoopback() || v4.IsLinkLocalUnicast() {
			return
		}
		for _, have := range out {
			if have == v4.String() {
				return
			}
		}
		out = append(out, v4.String())
	}
	// The address the system would use to reach the internet (no packet is sent for UDP "dial").
	if conn, err := net.Dial("udp4", "192.0.2.1:9"); err == nil {
		if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok {
			add(addr.IP)
		}
		conn.Close()
	}
	var rest []string
	if ifaces, err := net.Interfaces(); err == nil {
		for _, iface := range ifaces {
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}
			addrs, _ := iface.Addrs()
			for _, a := range addrs {
				if ipnet, ok := a.(*net.IPNet); ok && ipnet.IP.To4() != nil && isPrivate(ipnet.IP) {
					rest = append(rest, ipnet.IP.To4().String())
				}
			}
		}
	}
	sort.Strings(rest)
	for _, ip := range rest {
		add(net.ParseIP(ip))
	}
	return out
}

func isPrivate(ip net.IP) bool {
	v4 := ip.To4()
	return v4 != nil && (v4[0] == 10 || (v4[0] == 172 && v4[1] >= 16 && v4[1] <= 31) || (v4[0] == 192 && v4[1] == 168) ||
		(v4[0] == 100 && v4[1] >= 64 && v4[1] <= 127)) // the last range is Tailscale's
}

func serverURL(ip string, port int) string {
	return "http://" + net.JoinHostPort(ip, strconv.Itoa(port))
}

// inviteURL is the pairing link shown as a QR code. Erhu on the iPhone opens it as a filled-in
// "Add server" form. It never contains the password.
// remote is the away-from-home HTTPS address, if one is on.
func inviteURL(address, remote, username, name string) string {
	q := url.Values{}
	q.Set("url", address)
	if remote != "" {
		q.Set("remote", remote)
	}
	if username != "" {
		q.Set("user", username)
	}
	if name != "" {
		q.Set("name", name)
	}
	return "erhu://server?" + strings.ReplaceAll(q.Encode(), "+", "%20")
}

func computerName() string {
	name, err := os.Hostname()
	if err != nil || name == "" {
		return "Erhu Server"
	}
	return strings.TrimSuffix(name, ".local")
}

// portFree reports whether a TCP port can be listened on.
func portFree(port int) bool {
	l, err := net.Listen("tcp", ":"+strconv.Itoa(port))
	if err != nil {
		return false
	}
	l.Close()
	return true
}
