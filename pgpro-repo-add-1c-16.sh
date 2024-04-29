#!/bin/sh
# This script finds out which Postgresql for 1C 16 package repository is
# best suited for your linux distribution and adds it to your
# package manager. If repository is password protected, it would ask
# for your username and password and record them into package manager
# configuration.

REPO="http://repo.postgrespro.ru/1c/1c-16"
PRODUCT_NAME="Postgresql for 1C 16"
LISTNAME="postgresql-1c-16"
REPOUSER=
PASSWORD=
if [ "$(id -u)" -ne 0 ]; then
	echo "This script should be run as root, because it updates "
	echo "your package manager configuration"
	exit 1
fi
if [ ! -f "/etc/os-release" ]; then
	echo "/etc/os-release not found. It is either very all or misconfigured distribution" >&2
	exit 1
fi
. /etc/os-release
case "$ID" in
debian|ubuntu)
	PKGMGR=apt
	top="$REPO/$ID"
	# Some older version of Debian don't have version codename in
	# /etc/os-release
	if [ -z "$VERSION_CODENAME" ]; then
		VERSION_CODENAME="$(echo "$VERSION"|sed -e 's/^.*(//' -e 's/).*$//')"
	fi
	distr="$VERSION_CODENAME"
	;;
astra)
	PKGMGR=apt
	case "$VERSION_ID" in
	*.*.*) distver="${VERSION_ID%.*}"
		;;
	*.*_*) distver="${VERSION_ID%_*}"
		;;
	*.*) distver="${VERSION_ID}"
		;;
    esac
	if [ -z "$VARIANT_ID" ]; then
		case "$VERSION_ID" in
		*_arm)
			VARIANT_ID="novorossijsk"
		;;
		*_x86-64)
			VARIANT_ID="smolensk"
		;;
		*)
		:
		;;
		esac
	fi
	top="$REPO/$ID-${VARIANT_ID:-smolensk}/$distver"
	distr="${VERSION_CODENAME:-$VARIANT_ID}"
	;;
osnova)
	PKGMGR=apt
	top=$REPO/$ID
	distr=$VARIANT_ID
	;;
altlinux)
	PKGMGR=apt
	# Determine architecture. We cannot get architecture neither from kernel
	# (uname -m), nor from rpmbuild %{_arch} macro, because it doesn't
	# properly distinguish between subparch on e2k when they are running
	# in LXC containers. So we are trying to install packages for same
	# archtecture as rpm package.

	ARCH=$(rpm -q --qf="%{arch}" rpm)
	if [ "$ARCH" = "e2kv5" ]||[ "$ARCH" = "e2kv6" ]; then
		ARCH=e2kv4
	fi
	# Determine repository - we use different repositories for sp/spt and
	# generic releases
	case "$CPE_NAME" in
	*:sp*:*)
		DISTR=altlinux-spt
		case "$VERSION_ID" in
		7.*) DISTVERSION=7
		;;
		8.[01]) case "$ARCH" in
			e2k*) DISTVERSION=8.2
			;;
			*) DISTVERSION=8
			;;
			esac
			;;
		8.*) DISTVERSION=8.2
		;;
		10)
			DISTVERSION=10
		;;
		*) echo "Unknown version of Alt SP: $VERSION_ID";
			exit 1;
		;;
		esac
	;;
	*) DISTR=altlinux
	   verid=${VERSION_ID#p}
	   DISTVERSION=${verid%%.*}
	;;
	esac
	CHECK_URL=$REPO/$DISTR/$DISTVERSION/$ARCH/base/release
;;
alteros|goslinux|rhel|rosa)
	DISTR=$ID
	PKGMGR=yum
	;;
redos)
	DISTR=$ID
	PKGMGR=yum
	# We build different package for redos 7.2 and redos 7.3
	case "$VERSION_ID" in
	7.[012]*)
		:
		;;
	*) FORCE_RELEASEVER=7.3
	;;
	esac
	;;
centos|rocky|ol|almalinux|msvsphere)
	DISTR=rhel
	PKGMGR=yum
	;;
rels)
	PKGMGR=yum
	case $VERSION in
	*Helium*)
	DISTR=rosa-el
	;;
	*Cobalt*)
	DISTR=rosa-sx
	;;
	*)
	echo "Unsupported distribution $PRETTY_NAME" >&2
	exit 1
	;;
	esac
;;
sles|*suse*) PKGMGR=zypper
	DISTR=sles
	;;
*)	echo "Unsupported distribution '$NAME'" 1>&2
	exit 1
	;;
esac
if [ "$PKGMGR" = "apt" ]; then
	[ -z  "$ARCH" ] && ARCH="$(dpkg --print-architecture)"
	[ -z "$CHECK_URL" ] && CHECK_URL="$top/dists/$distr/main/binary-${ARCH}/Release"
	repofile="/etc/apt/sources.list.d/${LISTNAME}.list"
elif [ "$PKGMGR" = "yum" ]; then
   # We need to find out yum/dnf variables releasever and basearch
   if [ -x /usr/bin/dnf ]; then
     # Different distributions use different location for sysem python
	 # which execute dnf, so get right one from dnf itself
     python=$(head -1 /usr/bin/dnf|sed 's/^#! *//')
     yumvars=$(${python} -c 'import dnf; db = dnf.dnf.Base(); print(db.conf.substitutions["releasever"]+"/os/"+db.conf.substitutions["basearch"])')
   else
    yumvars=$(python -c 'import yum; yb = yum.YumBase(); print yb.conf.yumvar["releasever"]+"/os/"+yb.conf.yumvar["basearch"]'|tail -1)
   fi
   ARCH=${yumvars##*/}
   if [ -n "$FORCE_RELEASEVER" ]; then
		yumvars="$FORCE_RELEASEVER/os/$ARCH"
   fi
   CHECK_URL=$REPO/$DISTR/$yumvars/rpms/repodata/repomd.xml
   repofile=/etc/yum.repos.d/${LISTNAME}.repo

else
   CHECK_URL=$REPO/$DISTR/${VERSION_ID%%.*}/repodata/repomd.xml
   repofile=/etc/zypp/repos.d/${LISTNAME}.repo
   ARCH=$(rpm --eval '%{_arch}')
fi

if [ -f "$repofile" ]; then
	echo "You have already added repository for $PRODUCT_NAME to your system."
	echo "To upgrade your $PRODUCT_NAME packages use $PKGMGR install or"
	echo "$PKGMGR upgrade command."
	echo "If you are sure that you want to replace repository configuration,"
	echo "remove ${repofile} and run this script again."
	exit 1
fi
if [ "$ARCH" = "i386" ]; then
    echo "Version ${VERSION_ID} of ${NAME} distribution is not supported" \
         "for archtecture ${ARCH}"  >&2
	exit 1
fi

# Determine how to handle apt passwords

if [ "$PKGMGR" = "apt" ]; then
	if  [ -d /etc/apt/auth.conf.d ]; then
		APT_AUTH_CONF=yes
	else
		APT_AUTH_CONF=no
	fi
fi

if [ -x /usr/bin/wget ]; then
	# Checking existence of repository
	exitcode=99
	while [ "$exitcode" -ne 0 ]; do
	# We intend word splitting here - we subsituting 2 wget args when
	# shell var REPOUSER is not empty.
	wget -O - ${REPOUSER:+--user="$REPOUSER" --password="$PASSWORD"} "$CHECK_URL" >/dev/null
	exitcode=$?
	case "$exitcode" in
	5)  echo "SSL certificate verification error. Please check that you " >&2
		echo "have up to date CA certificate bundle installed." >&2
		if [ "$PKGMGR" = "apt" ]; then
			echo "it is in the ca-certificates package." >&2
		fi
		exit 5
		;;

	8)
		echo "Version ${VERSION_ID} of ${NAME} distribution is not supported" \
		     "for architecture ${ARCH}" >&2
		exit 1
	;;
	6) echo "Repository $REPO is password protected" >&2
		read -p "Please enter username ${REPOUSER:+(Press enter for $REPOUSER)}: " -r newuser
		if [ -n "$newuser" ]; then
			REPOUSER="$newuser"
		fi
		stty -echo
		read -p "Please enter your password (wouldn't be echoed): " -r PASSWORD
		echo ""
		stty echo
	   ;;

	0) # repository testing is successful
	   :
	esac
	done
else
	echo "WARNING: wget program not found. Cannot check repository access."
	echo "If you have login/password to access repository, please write them"
	if [ "$PKGMGR" = "apt" ]; then
		if [ "$APT_AUTH_CONF" = "yes" ]; then
			echo "into /etc/apt/auth.conf by hand. See apt_auth.conf(5)"
		else
			echo "into /etc/apt/sources.list.d/$LISTNAME.list by hand"
		fi
	else
		echo "into repository configuration file"
	fi
	echo "Press ENTER to continue, Ctrl-C to abort"
	read -r _
fi

if [ -d /etc/pki/rpm-gpg ]; then
	keyfile=/etc/pki/rpm-gpg/RPM-GPG-KEY-POSTGRESPRO
else
	keyfile=${HOME}/GPG-KEY-POSTGRESPRO
fi

cat > "$keyfile" << KEY-PGPRO
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1

mQENBFWdEjABCAC6QeLt0UJUQlDI2Z+R/y1OyOMU+5Te176I0+/Xpc2v5NsucW2M
kLTdOif0iW+q5h1djL+Pc5yu1fojZCvcihhbURnWECF52BmRnOC9jI0eTHq3fcPZ
IE3gqMJSn5sx2kJZ7n8XE0RbQ/hr51BLI+lzeqR3JAKBIqpVDKRrdP9Y1xVR/7Ne
q4FNR+osm6W4sM9G+TA/YADrWX3/TPXA4AN+2uNCNY0wK7em8V0oSZJVpEzvu5EP
djC6GX08XSvhPNo52o3u3tpFWH7ICw2BEYe672bJTjmi8wFgPW04pw49Jpvw4i1R
RhkpQqQ/b9bSveoNpvN32ElAJSaize76+q/TABEBAAG0KlJvYm90IChTaWduaW5n
IHJlcG9zKSA8ZGJhQHBvc3RncmVzcHJvLnJ1PokBOAQTAQIAIgUCVZ0SMAIbAwYL
CQgHAwIGFQgCCQoLBBYCAwECHgECF4AACgkQf5rlpi0t8LQpKQgAuJkOKNdnCSCt
GbNTwAbk414UPYa2B1M1DD6MfcSd6NnJNBVtRoaSWWISQB6gP+/w1jmD8XZbj/oH
5HAHjOyh9Lb3z1xeMIQnBnfGtcqmU5QrF55Yi0H9G0s+fn9oodfNXqAa/zARpBw6
q3LRSBCjT50/XA5G3AzUr7fIDb68FmEOCQukzs0uWBr5fkrRC21b1DcuhzbBay8X
pnlpB+Ma1PTIFgRdRl/KwYTzO80TWFMCeYfXQRh8StuQxRcVCqnv4F6seHqmbL7A
vOZ7GMymsz/IRHGVk4eVC6/94Y3vkV/0eQ+Yom+NtAFnep6G4OhxIeviZ697eFYF
+j4YsyDD+g==
=Q7MS
-----END PGP PUBLIC KEY BLOCK-----
KEY-PGPRO
if [ -d /etc/apt/trusted.gpg.d ]; then
	# /etc/apt/trusted.gpg.d should contain binary keys, not # ascii-armored
	sed -n '/^$/,/=$/p' "$keyfile" | base64 -d > "/etc/apt/trusted.gpg.d/postgrespro.gpg"
	rm -f "$keyfile"
fi

if [ "$ID" = "altlinux" ]; then
	# Altlinux apt-rpm
	# Check for apt-https which might be not installed
	if [ ${REPO%%://} = "https" ] && ! rpm -q apt-https > /dev/null; then
		echo "Package apt-https is required to access this pepository"
		apt-get install -y apt-https || exit 1
	fi
	echo "# Repositiory for '$PRODUCT_NAME'" > "$repofile"
	# Alt linux doesn't support apt auth.conf`x, so password should be
	# into URL directly and list file itself protected from
	# nonauthorized readers
	if  [ -n "$REPOUSER" ]; then
		proto="${REPO%%://*}"
		host="${REPO#*://}"
		top="$proto://$REPOUSER:$PASSWORD@$host/$DISTR/$DISTVERSION"
		chmod 0600 "/etc/apt/sources.list.d/$LISTNAME.list"
	else
		top="$REPO/$DISTR/$DISTVERSION"
	fi
	echo "rpm $top $ARCH pgpro" >> "${repofile}"
	echo "rpm $top noarch pgpro" >> "${repofile}"
	apt-get update
elif [ "$PKGMGR" = "apt" ]; then
	# Check for apt-transport-https which might be not installed
	if [ ${REPO%%://} = "https" ] && ! dpkg-query -W apt-transport-https > /dev/null; then
		echo "Package apt-transport-https is required to access this pepository"
		apt-get install -y apt-transport-https || exit 1
	fi
	echo "# Repositiory for '$PRODUCT_NAME'" > "$repofile"
	echo "deb $top $distr main" >> "${repofile}"
	if [ -n "$REPOUSER" ]; then
		if  [ "$APT_AUTH_CONF" = "yes" ]; then
			repohost=${REPO#*://}
			repohost=${repohost%%/*}
			cat > "/etc/apt/auth.conf.d/${repohost}.conf" <<EOF
machine ${repohost}
login $REPOUSER
password $PASSWORD
EOF
			chmod 0600 "/etc/apt/auth.conf.d/${repohost}.conf"
			echo "Your username/password are saved to /etc/apt/auth.conf.d/${repohost}.conf"
		else
			sed -i "s!://!://$REPOUSER:$PASSWORD@!" "${repofile}"
			chmod 0600 "${repofile}"
			echo "Your username and password are saved in ${repofile}"
		fi
	fi
	apt-get update
elif [ "$PKGMGR" = "yum" ]; then
	# write epel public keys
	# pgpro repository might contain packages copied from EPEL with their
	# signatures, so we are adding EPEL keys to our gpg key file
	cat >> "$keyfile" << KEYS-EPEL
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.4.5 (GNU/Linux)

mQINBEvSKUIBEADLGnUj24ZVKW7liFN/JA5CgtzlNnKs7sBg7fVbNWryiE3URbn1
JXvrdwHtkKyY96/ifZ1Ld3lE2gOF61bGZ2CWwJNee76Sp9Z+isP8RQXbG5jwj/4B
M9HK7phktqFVJ8VbY2jfTjcfxRvGM8YBwXF8hx0CDZURAjvf1xRSQJ7iAo58qcHn
XtxOAvQmAbR9z6Q/h/D+Y/PhoIJp1OV4VNHCbCs9M7HUVBpgC53PDcTUQuwcgeY6
pQgo9eT1eLNSZVrJ5Bctivl1UcD6P6CIGkkeT2gNhqindRPngUXGXW7Qzoefe+fV
QqJSm7Tq2q9oqVZ46J964waCRItRySpuW5dxZO34WM6wsw2BP2MlACbH4l3luqtp
Xo3Bvfnk+HAFH3HcMuwdaulxv7zYKXCfNoSfgrpEfo2Ex4Im/I3WdtwME/Gbnwdq
3VJzgAxLVFhczDHwNkjmIdPAlNJ9/ixRjip4dgZtW8VcBCrNoL+LhDrIfjvnLdRu
vBHy9P3sCF7FZycaHlMWP6RiLtHnEMGcbZ8QpQHi2dReU1wyr9QgguGU+jqSXYar
1yEcsdRGasppNIZ8+Qawbm/a4doT10TEtPArhSoHlwbvqTDYjtfV92lC/2iwgO6g
YgG9XrO4V8dV39Ffm7oLFfvTbg5mv4Q/E6AWo/gkjmtxkculbyAvjFtYAQARAQAB
tCFFUEVMICg2KSA8ZXBlbEBmZWRvcmFwcm9qZWN0Lm9yZz6JAjYEEwECACAFAkvS
KUICGw8GCwkIBwMCBBUCCAMEFgIDAQIeAQIXgAAKCRA7Sd8qBgi4lR/GD/wLGPv9
qO39eyb9NlrwfKdUEo1tHxKdrhNz+XYrO4yVDTBZRPSuvL2yaoeSIhQOKhNPfEgT
9mdsbsgcfmoHxmGVcn+lbheWsSvcgrXuz0gLt8TGGKGGROAoLXpuUsb1HNtKEOwP
Q4z1uQ2nOz5hLRyDOV0I2LwYV8BjGIjBKUMFEUxFTsL7XOZkrAg/WbTH2PW3hrfS
WtcRA7EYonI3B80d39ffws7SmyKbS5PmZjqOPuTvV2F0tMhKIhncBwoojWZPExft
HpKhzKVh8fdDO/3P1y1Fk3Cin8UbCO9MWMFNR27fVzCANlEPljsHA+3Ez4F7uboF
p0OOEov4Yyi4BEbgqZnthTG4ub9nyiupIZ3ckPHr3nVcDUGcL6lQD/nkmNVIeLYP
x1uHPOSlWfuojAYgzRH6LL7Idg4FHHBA0to7FW8dQXFIOyNiJFAOT2j8P5+tVdq8
wB0PDSH8yRpn4HdJ9RYquau4OkjluxOWf0uRaS//SUcCZh+1/KBEOmcvBHYRZA5J
l/nakCgxGb2paQOzqqpOcHKvlyLuzO5uybMXaipLExTGJXBlXrbbASfXa/yGYSAG
iVrGz9CE6676dMlm8F+s3XXE13QZrXmjloc6jwOljnfAkjTGXjiB7OULESed96MR
XtfLk0W5Ab9pd7tKDR6QHI7rgHXfCopRnZ2VVQ==
=V/6I
-----END PGP PUBLIC KEY BLOCK-----
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: GnuPG v1.4.11 (GNU/Linux)

mQINBFKuaIQBEAC1UphXwMqCAarPUH/ZsOFslabeTVO2pDk5YnO96f+rgZB7xArB
OSeQk7B90iqSJ85/c72OAn4OXYvT63gfCeXpJs5M7emXkPsNQWWSju99lW+AqSNm
jYWhmRlLRGl0OO7gIwj776dIXvcMNFlzSPj00N2xAqjMbjlnV2n2abAE5gq6VpqP
vFXVyfrVa/ualogDVmf6h2t4Rdpifq8qTHsHFU3xpCz+T6/dGWKGQ42ZQfTaLnDM
jToAsmY0AyevkIbX6iZVtzGvanYpPcWW4X0RDPcpqfFNZk643xI4lsZ+Y2Er9Yu5
S/8x0ly+tmmIokaE0wwbdUu740YTZjCesroYWiRg5zuQ2xfKxJoV5E+Eh+tYwGDJ
n6HfWhRgnudRRwvuJ45ztYVtKulKw8QQpd2STWrcQQDJaRWmnMooX/PATTjCBExB
9dkz38Druvk7IkHMtsIqlkAOQMdsX1d3Tov6BE2XDjIG0zFxLduJGbVwc/6rIc95
T055j36Ez0HrjxdpTGOOHxRqMK5m9flFbaxxtDnS7w77WqzW7HjFrD0VeTx2vnjj
GqchHEQpfDpFOzb8LTFhgYidyRNUflQY35WLOzLNV+pV3eQ3Jg11UFwelSNLqfQf
uFRGc+zcwkNjHh5yPvm9odR1BIfqJ6sKGPGbtPNXo7ERMRypWyRz0zi0twARAQAB
tChGZWRvcmEgRVBFTCAoNykgPGVwZWxAZmVkb3JhcHJvamVjdC5vcmc+iQI4BBMB
AgAiBQJSrmiEAhsPBgsJCAcDAgYVCAIJCgsEFgIDAQIeAQIXgAAKCRBqL66iNSxk
5cfGD/4spqpsTjtDM7qpytKLHKruZtvuWiqt5RfvT9ww9GUUFMZ4ZZGX4nUXg49q
ixDLayWR8ddG/s5kyOi3C0uX/6inzaYyRg+Bh70brqKUK14F1BrrPi29eaKfG+Gu
MFtXdBG2a7OtPmw3yuKmq9Epv6B0mP6E5KSdvSRSqJWtGcA6wRS/wDzXJENHp5re
9Ism3CYydpy0GLRA5wo4fPB5uLdUhLEUDvh2KK//fMjja3o0L+SNz8N0aDZyn5Ax
CU9RB3EHcTecFgoy5umRj99BZrebR1NO+4gBrivIfdvD4fJNfNBHXwhSH9ACGCNv
HnXVjHQF9iHWApKkRIeh8Fr2n5dtfJEF7SEX8GbX7FbsWo29kXMrVgNqHNyDnfAB
VoPubgQdtJZJkVZAkaHrMu8AytwT62Q4eNqmJI1aWbZQNI5jWYqc6RKuCK6/F99q
thFT9gJO17+yRuL6Uv2/vgzVR1RGdwVLKwlUjGPAjYflpCQwWMAASxiv9uPyYPHc
ErSrbRG0wjIfAR3vus1OSOx3xZHZpXFfmQTsDP7zVROLzV98R3JwFAxJ4/xqeON4
vCPFU6OsT3lWQ8w7il5ohY95wmujfr6lk89kEzJdOTzcn7DBbUru33CQMGKZ3Evt
RjsC7FDbL017qxS+ZVA/HGkyfiu4cpgV8VUnbql5eAZ+1Ll6Dw==
=hdPa
-----END PGP PUBLIC KEY BLOCK-----
-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBFz3zvsBEADJOIIWllGudxnpvJnkxQz2CtoWI7godVnoclrdl83kVjqSQp+2
dgxuG5mUiADUfYHaRQzxKw8efuQnwxzU9kZ70ngCxtmbQWGmUmfSThiapOz00018
+eo5MFabd2vdiGo1y+51m2sRDpN8qdCaqXko65cyMuLXrojJHIuvRA/x7iqOrRfy
a8x3OxC4PEgl5pgDnP8pVK0lLYncDEQCN76D9ubhZQWhISF/zJI+e806V71hzfyL
/Mt3mQm/li+lRKU25Usk9dWaf4NH/wZHMIPAkVJ4uD4H/uS49wqWnyiTYGT7hUbi
ecF7crhLCmlRzvJR8mkRP6/4T/F3tNDPWZeDNEDVFUkTFHNU6/h2+O398MNY/fOh
yKaNK3nnE0g6QJ1dOH31lXHARlpFOtWt3VmZU0JnWLeYdvap4Eff9qTWZJhI7Cq0
Wm8DgLUpXgNlkmquvE7P2W5EAr2E5AqKQoDbfw/GiWdRvHWKeNGMRLnGI3QuoX3U
pAlXD7v13VdZxNydvpeypbf/AfRyrHRKhkUj3cU1pYkM3DNZE77C5JUe6/0nxbt4
ETUZBTgLgYJGP8c7PbkVnO6I/KgL1jw+7MW6Az8Ox+RXZLyGMVmbW/TMc8haJfKL
MoUo3TVk8nPiUhoOC0/kI7j9ilFrBxBU5dUtF4ITAWc8xnG6jJs/IsvRpQARAQAB
tChGZWRvcmEgRVBFTCAoOCkgPGVwZWxAZmVkb3JhcHJvamVjdC5vcmc+iQI4BBMB
AgAiBQJc9877AhsPBgsJCAcDAgYVCAIJCgsEFgIDAQIeAQIXgAAKCRAh6kWrL4bW
oWagD/4xnLWws34GByVDQkjprk0fX7Iyhpm/U7BsIHKspHLL+Y46vAAGY/9vMvdE
0fcr9Ek2Zp7zE1RWmSCzzzUgTG6BFoTG1H4Fho/7Z8BXK/jybowXSZfqXnTOfhSF
alwDdwlSJvfYNV9MbyvbxN8qZRU1z7PEWZrIzFDDToFRk0R71zHpnPTNIJ5/YXTw
NqU9OxII8hMQj4ufF11040AJQZ7br3rzerlyBOB+Jd1zSPVrAPpeMyJppWFHSDAI
WK6x+am13VIInXtqB/Cz4GBHLFK5d2/IYspVw47Solj8jiFEtnAq6+1Aq5WH3iB4
bE2e6z00DSF93frwOyWN7WmPIoc2QsNRJhgfJC+isGQAwwq8xAbHEBeuyMG8GZjz
xohg0H4bOSEujVLTjH1xbAG4DnhWO/1VXLX+LXELycO8ZQTcjj/4AQKuo4wvMPrv
9A169oETG+VwQlNd74VBPGCvhnzwGXNbTK/KH1+WRH0YSb+41flB3NKhMSU6dGI0
SGtIxDSHhVVNmx2/6XiT9U/znrZsG5Kw8nIbbFz+9MGUUWgJMsd1Zl9R8gz7V9fp
n7L7y5LhJ8HOCMsY/Z7/7HUs+t/A1MI4g7Q5g5UuSZdgi0zxukiWuCkLeAiAP4y7
zKK4OjJ644NDcWCHa36znwVmkz3ixL8Q0auR15Oqq2BjR/fyog==
=84m8
-----END PGP PUBLIC KEY BLOCK-----

-----BEGIN PGP PUBLIC KEY BLOCK-----

mQINBGE3mOsBEACsU+XwJWDJVkItBaugXhXIIkb9oe+7aadELuVo0kBmc3HXt/Yp
CJW9hHEiGZ6z2jwgPqyJjZhCvcAWvgzKcvqE+9i0NItV1rzfxrBe2BtUtZmVcuE6
2b+SPfxQ2Hr8llaawRjt8BCFX/ZzM4/1Qk+EzlfTcEcpkMf6wdO7kD6ulBk/tbsW
DHX2lNcxszTf+XP9HXHWJlA2xBfP+Dk4gl4DnO2Y1xR0OSywE/QtvEbN5cY94ieu
n7CBy29AleMhmbnx9pw3NyxcFIAsEZHJoU4ZW9ulAJ/ogttSyAWeacW7eJGW31/Z
39cS+I4KXJgeGRI20RmpqfH0tuT+X5Da59YpjYxkbhSK3HYBVnNPhoJFUc2j5iKy
XLgkapu1xRnEJhw05kr4LCbud0NTvfecqSqa+59kuVc+zWmfTnGTYc0PXZ6Oa3rK
44UOmE6eAT5zd/ToleDO0VesN+EO7CXfRsm7HWGpABF5wNK3vIEF2uRr2VJMvgqS
9eNwhJyOzoca4xFSwCkc6dACGGkV+CqhufdFBhmcAsUotSxe3zmrBjqA0B/nxIvH
DVgOAMnVCe+Lmv8T0mFgqZSJdIUdKjnOLu/GRFhjDKIak4jeMBMTYpVnU+HhMHLq
uDiZkNEvEEGhBQmZuI8J55F/a6UURnxUwT3piyi3Pmr2IFD7ahBxPzOBCQARAQAB
tCdGZWRvcmEgKGVwZWw5KSA8ZXBlbEBmZWRvcmFwcm9qZWN0Lm9yZz6JAk4EEwEI
ADgWIQT/itE0RZcQbs6BO5GKOHK/MihGfAUCYTeY6wIbDwULCQgHAgYVCgkICwIE
FgIDAQIeAQIXgAAKCRCKOHK/MihGfFX/EACBPWv20+ttYu1A5WvtHJPzwbj0U4yF
3zTQpBglQ2UfkRpYdipTlT3Ih6j5h2VmgRPtINCc/ZE28adrWpBoeFIS2YAKOCLC
nZYtHl2nCoLq1U7FSttUGsZ/t8uGCBgnugTfnIYcmlP1jKKA6RJAclK89evDQX5n
R9ZD+Cq3CBMlttvSTCht0qQVlwycedH8iWyYgP/mF0W35BIn7NuuZwWhgR00n/VG
4nbKPOzTWbsP45awcmivdrS74P6mL84WfkghipdmcoyVb1B8ZP4Y/Ke0RXOnLhNe
CfrXXvuW+Pvg2RTfwRDtehGQPAgXbmLmz2ZkV69RGIr54HJv84NDbqZovRTMr7gL
9k3ciCzXCiYQgM8yAyGHV0KEhFSQ1HV7gMnt9UmxbxBE2pGU7vu3CwjYga5DpwU7
w5wu1TmM5KgZtZvuWOTDnqDLf0cKoIbW8FeeCOn24elcj32bnQDuF9DPey1mqcvT
/yEo/Ushyz6CVYxN8DGgcy2M9JOsnmjDx02h6qgWGWDuKgb9jZrvRedpAQCeemEd
fhEs6ihqVxRFl16HxC4EVijybhAL76SsM2nbtIqW1apBQJQpXWtQwwdvgTVpdEtE
r4ArVJYX5LrswnWEQMOelugUG6S3ZjMfcyOa/O0364iY73vyVgaYK+2XtT2usMux
VL469Kj5m13T6w==
=Mjs/
-----END PGP PUBLIC KEY BLOCK-----
KEYS-EPEL

	#generate repo file
	if [ -n "$FORCE_RELEASEVER" ]; then
		RELEASEVER="$FORCE_RELEASEVER"
	else
		RELEASEVER="\$releasever"
	fi
	cat > "$repofile" << REPOFILE
[$LISTNAME]
name=$PRODUCT_NAME for $DISTR
baseurl=$REPO/$DISTR/$RELEASEVER/os/\$basearch/rpms
enabled=1
gpgcheck=1
gpgkey=file://$keyfile
REPOFILE
	if [ -n "$REPOUSER" ]; then
		chmod 0600 "$repofile"
		echo "username=$REPOUSER" >> "$repofile"
		echo "password=$PASSWORD" >> "$repofile"
	fi
else
	#write opensuse public key
	#pgpro repository for SLES might contain packages from OpenSUSE
	#So we are adding OpenSUSE keys to our GPG key file
	cat >> "$keyfile" << KEYS-OPENSUSE
-----BEGIN PGP PUBLIC KEY BLOCK-----
Version: rpm-4.14.1 (NSS-3)

mQENBEkUTD8BCADWLy5d5IpJedHQQSXkC1VK/oAZlJEeBVpSZjMCn8LiHaI9Wq3G
3Vp6wvsP1b3kssJGzVFNctdXt5tjvOLxvrEfRJuGfqHTKILByqLzkeyWawbFNfSQ
93/8OunfSTXC1Sx3hgsNXQuOrNVKrDAQUqT620/jj94xNIg09bLSxsjN6EeTvyiO
mtE9H1J03o9tY6meNL/gcQhxBvwuo205np0JojYBP0pOfN8l9hnIOLkA0yu4ZXig
oKOVmf4iTjX4NImIWldT+UaWTO18NWcCrujtgHueytwYLBNV5N0oJIP2VYuLZfSD
VYuPllv7c6O2UEOXJsdbQaVuzU1HLocDyipnABEBAAG0NG9wZW5TVVNFIFByb2pl
Y3QgU2lnbmluZyBLZXkgPG9wZW5zdXNlQG9wZW5zdXNlLm9yZz6JATwEEwECACYC
GwMGCwkIBwMCBBUCCAMEFgIDAQIeAQIXgAUCU2dN1AUJHR8ElQAKCRC4iy/UPb3C
hGQrB/9teCZ3Nt8vHE0SC5NmYMAE1Spcjkzx6M4r4C70AVTMEQh/8BvgmwkKP/qI
CWo2vC1hMXRgLg/TnTtFDq7kW+mHsCXmf5OLh2qOWCKi55Vitlf6bmH7n+h34Sha
Ei8gAObSpZSF8BzPGl6v0QmEaGKM3O1oUbbB3Z8i6w21CTg7dbU5vGR8Yhi9rNtr
hqrPS+q2yftjNbsODagaOUb85ESfQGx/LqoMePD+7MqGpAXjKMZqsEDP0TbxTwSk
4UKnF4zFCYHPLK3y/hSH5SEJwwPY11l6JGdC1Ue8Zzaj7f//axUs/hTC0UZaEE+a
5v4gbqOcigKaFs9Lc3Bj8b/lE10Y
=i2TA
-----END PGP PUBLIC KEY BLOCK-----

KEYS-OPENSUSE
	# add zypper repository
	if [ -n "$REPOUSER" ]; then
		proto=${REPO%://}
		host=${REPO#://}
		REPO=$proto://$REPOUSER:$PASSWORD@$host
	fi
	rpm --import "$keyfile" && rm -f "$keyfile"
	zypper --gpg-auto-import-keys addrepo -f "$REPO/$DISTR/${VERSION_ID%%.*}" "$LISTNAME"
	zypper --gpg-auto-import-keys refresh
fi
