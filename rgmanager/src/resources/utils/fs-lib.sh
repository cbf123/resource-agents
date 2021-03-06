#!/bin/bash
#
# Copyright (C) 1997-2003 Sistina Software, Inc.  All rights reserved.
# Copyright (C) 2004-2011 Red Hat, Inc.  All rights reserved.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#

#
# File system common functions
#

LC_ALL=C
LANG=C
PATH=/bin:/sbin:/usr/bin:/usr/sbin
export LC_ALL LANG PATH

# Define this value to 0 by default, bind-mount.sh or any other agent
# that uses this value will alter it after sourcing fs-lib.sh
export IS_BIND_MOUNT=0

# Private return codes
FAIL=2
NO=1
YES=0
YES_STR="yes"

[ -z "$OCF_RESOURCE_INSTANCE" ] && export OCF_RESOURCE_INSTANCE="filesystem:$OCF_RESKEY_name"

#
# Using a global to contain the return value saves
# clone() operations.  This is important to reduce
# resource consumption during status checks.
#
# There is no way to return a string from a function
# in bash without cloning the process, which is exactly
# what we are trying to avoid.  So, we have to resort
# to using a dedicated global variables.
declare REAL_DEVICE
declare STRIP_SLASHES=""
declare FINDMNT_OUTPUT=""

#
# Stub ocf_log function for when we are using
# quick_status, since ocf_log generally forks (and
# sourcing ocf-shellfuncs forks -a lot-).
#
ocf_log()
{
	echo $*
}

#
# Assume NFS_TRICKS are not available until we are
# proved otherwise.
#
export NFS_TRICKS=1

#
# Quick status doesn't fork() or clone() when using
# device files directly.  (i.e. not symlinks, LABEL= or
# UUID=
#
if [ "$1" = "status" -o "$1" = "monitor" ] &&
   [ "$OCF_RESKEY_quick_status" = "1" ]; then
	echo Using Quick Status

	# XXX maybe we can make ocf-shellfuncs have a 'quick' mode too?
	export OCF_SUCCESS=0
	export OCF_ERR_GENERIC=1
else
	#
	# Grab nfs lock tricks if available
	#
	if [ -f "$(dirname $0)/svclib_nfslock" ]; then
		. $(dirname $0)/svclib_nfslock
		NFS_TRICKS=0
	fi

	. $(dirname $0)/ocf-shellfuncs
fi


verify_name()
{
	if [ -z "$OCF_RESKEY_name" ]; then
		ocf_log err "No file system name specified."
		return $OCF_ERR_ARGS
	fi
	return $OCF_SUCCESS
}


verify_mountpoint()
{
	if [ -z "$OCF_RESKEY_mountpoint" ]; then
		ocf_log err "No mount point specified."
		return $OCF_ERR_ARGS
	fi

	if ! [ -e "$OCF_RESKEY_mountpoint" ]; then
		ocf_log info "Mount point $OCF_RESKEY_mountpoint will be "\
				"created at mount time."
		return $OCF_SUCCESS
	fi

	[ -d "$OCF_RESKEY_mountpoint" ] && return $OCF_SUCCESS

	ocf_log err "$OCF_RESKEY_mountpoint exists but is not a directory."

	return $OCF_ERR_ARGS
}


#
# This used to be called using $(...), but doing this causes bash
# to set up a pipe and clone().  So, the output of this function is
# stored in the global variable REAL_DEVICE, declared previously.
#
real_device()
{
	declare dev="$1"
	declare realdev

	if [ $IS_BIND_MOUNT -eq 1 ]; then
		REAL_DEVICE="$dev"
		return $OCF_SUCCESS
	fi
	REAL_DEVICE=""

	[ -z "$dev" ] && return $OCF_ERR_ARGS

	# Oops, we have a link.  Sorry, this is going to fork.
	if [ -h "$dev" ]; then
		realdev=$(readlink -f $dev)
		if [ $? -ne 0 ]; then
			return $OCF_ERR_ARGS
		fi
		REAL_DEVICE="$realdev"
		return $OCF_SUCCESS
	fi

	# If our provided blockdev is a device, we are done
	if [ -b "$dev" ]; then
		REAL_DEVICE="$dev"
		return $OCF_SUCCESS
	fi

	# It's not a link, it's not a block device.  If it also
	# does not match UUID= or LABEL=, then findfs is not
	# going to find anything useful, so we should quit now.
	if [ "${dev/UUID=/}" = "$dev" ] &&
	   [ "${dev/LABEL=/}" = "$dev" ]; then
		return $OCF_ERR_GENERIC
	fi

	# When using LABEL= or UUID=, we can't save a fork.
	realdev=$(findfs "$dev" 2> /dev/null)
	if [ -n "$realdev" ] && [ -b "$realdev" ]; then
		REAL_DEVICE="$realdev"
		return $OCF_SUCCESS
	fi

	return $OCF_ERR_GENERIC
}


verify_device()
{
	declare realdev

	if [ -z "$OCF_RESKEY_device" ]; then
	       ocf_log err "No device or label specified."
	       return $OCF_ERR_ARGS
	fi

	real_device "$OCF_RESKEY_device"
	realdev="$REAL_DEVICE"
	if [ -n "$realdev" ]; then
		if [ "$realdev" != "$OCF_RESKEY_device" ]; then
			ocf_log info "Specified $OCF_RESKEY_device maps to $realdev"
		fi
		return $OCF_SUCCESS
	fi

	ocf_log err "Device or label \"$OCF_RESKEY_device\" not valid"

	return $OCF_ERR_ARGS
}

list_mounts()
{
	if [ $IS_BIND_MOUNT -eq 1 ]; then
		cat /etc/mtab
	else
		cat /proc/mounts
	fi
}

##
# Tries to use findmnt util to return list
# of mountpoints for a device
#
# Global variables are used to reduce forking when capturing stdout.
#
# Return values
# 0 - device mount points found, mountpoint list returned to FINDMNT_OUTPUT global variable
# 1 - device mount not found
# 2 - findmnt tool isn't found or can not be used
#
##
try_findmnt()
{
	FINDMNT_OUTPUT=""

	case $OCF_RESKEY_use_findmnt in
	0|false|no|off)
		return 2 ;;
	*)
		: ;;
	esac

	which findmnt > /dev/null 2>&1
	if [ $? -eq 0 ]; then
		FINDMNT_OUTPUT="$(findmnt -o TARGET --noheadings $1)"
		if [ $? -ne 0 ]; then
			# workaround mount helpers inconsistency that still
			# add / on the device entry in /proc/mounts
			FINDMNT_OUTPUT="$(findmnt -o TARGET --noheadings $1/)"
			if [ $? -ne 0 ]; then
				return 1
			else
				return 0
			fi
		else
			return 0
		fi
	fi

	return 2
}

##
# Returns result in global variable to reduce forking
##
strip_trailing_slashes()
{
	local tmp=$1
	while [ "${tmp#${tmp%?}}" = "/" ]
	do
		tmp="${tmp%/}"
	done

	STRIP_SLASHES="$tmp"
}

#
# kill_procs_using_mount mount_point [signal]
# 
# Kill any processes using the specified mountpoint, using the optional 
# specified signal. This is used in place of fuser to avoid it becoming
# blocked while following symlinks to an unresponsive file system.  
# Defaults to SIGKILL if no signal specified. 
# 
kill_procs_using_mount () {
	declare mp
	declare procs
	declare mmap_procs

	if [ $# -lt 1 -o -z "$1" ]; then
		ocf_log err "Usage: kill_procs_using_mount mount_point [signal]"
		return $FAIL
	fi

	strip_trailing_slashes "$1"
	mp="$STRIP_SLASHES"

	if [ -z "$mp" ]; then
		ocf_log err "Usage: kill_procs_using_mount mount_point [signal]"
		return $FAIL
	fi

	# anything held open in mount point after the slash
	procs=$(find /proc/[0-9]*/ -type l -lname "${mp}/*" -or -lname "${mp}" 2>/dev/null | awk -F/ '{print $3}' | uniq)

	# anything with memory mapping to something in the mountpoint
	mmap_procs=$(grep " ${mp}" /proc/[0-9]*/maps | awk -F/ '{print $3}' | uniq)
	procs=$(echo -e "${procs}\n${mmap_procs}" | sort | uniq)

	for pid in $procs; do
		if [ -n "$2" ]; then
			kill -s $2 $pid
		else
			kill -s KILL $pid
		fi	
	done

	return $SUCCESS
}

#
# mount_in_use device mount_point
#
# Check to see if either the device or mount point are in use anywhere on
# the system.  It is not required that the device be mounted on the named
# moint point, just if either are in use.
#
mount_in_use () {
	declare mp tmp_mp
	declare tmp_type
	declare dev tmp_dev
	declare junkb junkc junkd
	declare res=$FAIL
	declare findmnt_res=2

	if [ $# -ne 2 ]; then
		ocf_log err "Usage: mount_in_use device mount_point".
		return $FAIL
	fi

	dev="$1"
	mp="$2"

	# First try and find out if the device has a mount point by
	# attempting to use the findmnt tool. It is much faster than
	# iterating through /proc/mounts
	try_findmnt $dev
	findmnt_res=$?
	if [ $findmnt_res -eq 0 ]; then
		case $OCF_RESKEY_fstype in
		cifs|nfs|nfs4)
			# -r means to include '/' character and not treat it as escape character
			while read -r tmp_mp
			do
				if [ "$tmp_mp" = "$mp" ]; then
					return $YES
				fi
			done < <(echo "$FINDMNT_OUTPUT")
			;;
		*)
			return $YES
			;;
		esac
	fi

	while read -r tmp_dev tmp_mp tmp_type junkb junkc junkd; do

		if [ "$tmp_type" = "autofs" ]; then
			continue
		fi 

		# Does the device match? We might have already tried findmnt
		# which is why this could get skipped
		if [ $findmnt_res -eq 2 ]; then
			if [ "${tmp_dev:0:1}" != "-" ]; then
				# XXX fork/clone warning XXX
				tmp_dev="$(printf "$tmp_dev")"
			fi

			strip_trailing_slashes "$tmp_dev"
			tmp_dev="$STRIP_SLASHES"
			if [ -n "$tmp_dev" -a "$tmp_dev" = "$dev" ]; then
				case $OCF_RESKEY_fstype in
				cifs|nfs|nfs4)
					;;
				*)
					return $YES
					;;
				esac
			fi
		fi

		# Mountpoint from /proc/mounts containing spaces will
		# have spaces represented in octal.  printf takes care
		# of this for us.
		tmp_mp="$(printf "$tmp_mp")"

		if [ -n "$tmp_mp" -a "$tmp_mp" = "$mp" ]; then
			return $YES
		fi
	done < <(list_mounts)

	return $NO
}

##
# Returns whether or not the device is mounted.
# If the mountpoint does not match the one provided, the
# mount point found is printed to stdout.
##
real_mountpoint()
{
	declare dev=$1
	declare mp=$2
	declare ret=$NO
	declare tmp_mp
	declare tmp_dev
	declare tmp_type
	declare found=1
	declare poss_mp=""

	try_findmnt $dev
	case $? in
	0)  #findmnt found mount points, loop through them to find a match

		# -r means to include '/' character and not treat it as escape character
		while read -r tmp_mp
		do
			ret=$YES
			if [ "$tmp_mp" != "$mp" ]; then
				poss_mp=$tmp_mp
			else
				found=0
				break
			fi
		done < <(echo "$FINDMNT_OUTPUT")
		;;
	1)
		# findmnt found no mount points for the device
		return $NO
		;;
	2)  # findmnt tool could not be used.
		# Using slow method reading /proc/mounts dir.
		while read -r tmp_dev tmp_mp tmp_type junk_b junk_c junk_d
		do
			if [ "$tmp_type" = "autofs" ]; then
				continue
			fi 

			if [ "${tmp_dev:0:1}" != "-" ]; then
				# XXX fork/clone warning XXX
				tmp_dev="$(printf "$tmp_dev")"
			fi

			# CIFS mounts can sometimes have trailing slashes
			# in their first field in /proc/mounts, so strip them.
			strip_trailing_slashes "$tmp_dev"
			tmp_dev="$STRIP_SLASHES"
			real_device "$tmp_dev"
			tmp_dev="$REAL_DEVICE"

			# XXX fork/clone warning XXX
			# Mountpoint from /proc/mounts containing spaces will
			# have spaces represented in octal.  printf takes care
			# of this for us.
			tmp_mp="$(printf "$tmp_mp")"

			if [ -n "$tmp_dev" -a "$tmp_dev" = "$dev" ]; then
				ret=$YES
				#
				# Check to see if its mounted in the right
				# place
				#
				if [ -n "$tmp_mp" ]; then
					if [ "$tmp_mp" != "$mp" ]; then
						poss_mp=$tmp_mp
					else
						found=0
						break
					fi
				fi
			fi
		done < <(list_mounts)
	esac

	if [ $found -ne 0 ]; then
		echo "$poss_mp"
	fi
	return $ret
}

#
# is_mounted device mount_point
#
# Check to see if the device is mounted.  Print a warning if its not
# mounted on the directory we expect it to be mounted on.
#
is_mounted () {

	declare mp
	declare dev
	declare ret=$FAIL
	declare poss_mp

	if [ $# -ne 2 ]; then
		ocf_log err "Usage: is_mounted device mount_point"
		return $FAIL
	fi

	real_device "$1"
	dev="$REAL_DEVICE"
	if [ -z "$dev" ]; then
		ocf_log err "$OCF_RESOURCE_INSTANCE: is_mounted: Could not match $1 with a real device"
		return $OCF_ERR_ARGS
	fi

	if [ -h "$2" ]; then
		mp="$(readlink -f $2)"
	else
		mp="$2"
	fi

	# This bash glyph simply removes a trailing slash
	# if one exists.  /a/b/ -> /a/b; /a/b -> /a/b.
	mp="${mp%/}"

	poss_mp=$(real_mountpoint "$dev" "$mp")
	ret=$?

	if [ $ret -eq $YES ] && [ -n "$poss_mp" ]; then
		# if we made it here, then the device is mounted, but not where
		# we expected it to be
		case $OCF_RESKEY_fstype in
		  cifs|nfs|nfs4)
		    ret=$NO
		    ;;
		  *)
		    ocf_log warn "Device $dev is mounted on $poss_mp instead of $mp"
		    ;;
		esac
	fi


	return $ret
}


#
# is_alive mount_point
#
# Check to see if mount_point is alive (testing read/write)
#
is_alive()
{
	declare errcode
	declare mount_point="$1"
	declare file
	declare rw

	if [ $# -ne 1 ]; then
	        ocf_log err "Usage: is_alive mount_point"
		return $FAIL
	fi

	[ -z "$OCF_CHECK_LEVEL" ] && export OCF_CHECK_LEVEL=0

	test -d "$mount_point"
	if [ $? -ne 0 ]; then
		ocf_log err "${OCF_RESOURCE_INSTANCE}: is_alive: $mount_point is not a directory"
		return $FAIL
	fi

	[ $OCF_CHECK_LEVEL -lt 10 ] && return $YES

	# depth 10 test (read test)
	ls "$mount_point" > /dev/null 2> /dev/null
	errcode=$?
	if [ $errcode -ne 0 ]; then
		ocf_log err "${OCF_RESOURCE_INSTANCE}: is_alive: failed read test on [$mount_point]. Return code: $errcode"
		return $NO
	fi

	[ $OCF_CHECK_LEVEL -lt 20 ] && return $YES

	# depth 20 check (write test)
	rw=$YES
	for o in `echo $OCF_RESKEY_options | sed -e s/,/\ /g`; do
                if [ "$o" = "ro" ]; then
		        rw=$NO
                fi
	done
	if [ $rw -eq $YES ]; then
		file=$(mktemp "$mount_point/.check_writable.$(hostname).XXXXXX")
		if [ ! -e "$file" ]; then
			ocf_log err "${OCF_RESOURCE_INSTANCE}: is_alive: failed write test on [$mount_point]. Return code: $errcode"
			return $NO
		fi
		rm -f $file > /dev/null 2> /dev/null
	fi

	return $YES
}


#
# Decide which quota options are enabled and return a string
# which we can pass to quotaon
#
quota_opts()
{
	declare quotaopts=""
	declare opts="$1"
	declare mopt

	for mopt in `echo $opts | sed -e s/,/\ /g`; do
		case $mopt in
		quota)
			quotaopts="gu"
			break
			;;
		usrquota)
			quotaopts="u$quotaopts"
			continue
			;;
		grpquota)
			quotaopts="g$quotaopts"
			continue
			;;
		noquota)
			quotaopts=""
			return 0
			;;
		esac
	done

	echo $quotaopts
	return 0
}



#
# Enable quotas on the mount point if the user requested them
#
enable_fs_quotas()
{
	declare -i need_check=0
	declare -i rv
	declare quotaopts=""
	declare mopt
	declare opts="$1"
	declare mp="$2"

	if ! type quotaon &> /dev/null; then
		ocf_log err "quotaon not found in $PATH"
		return $OCF_ERR_GENERIC
	fi

	quotaopts=$(quota_opts $opts)
	[ -z "$quotaopts" ] && return 0

	ocf_log debug "quotaopts = $quotaopts"

	# Ok, create quota files if they don't exist
	for f in quota.user aquota.user quota.group aquota.group; do
		if ! [ -f "$mp/$f" ]; then
			ocf_log info "$mp/$f was missing - creating"
			touch "$mp/$f"
			chmod 600 "$mp/$f"
			need_check=1
		fi
	done

	if [ $need_check -eq 1 ]; then
		ocf_log info "Checking quota info in $mp"
		quotacheck -$quotaopts "$mp"
	fi

	ocf_log info "Enabling Quotas on $mp"
	ocf_log debug "quotaon -$quotaopts \"$mp\""
	quotaon -$quotaopts "$mp"
	rv=$?
	if [ $rv -ne 0 ]; then
		# Just a warning
		ocf_log warn "Unable to turn on quotas for $mp; return = $rv"
	fi

	return $rv
}


# Agent-specific actions to take before mounting
# (if required).  Typically things like fsck.
do_pre_mount() {
	return 0
}

# Default mount handler - for block devices
#
do_mount() {
	declare dev="$1"
	declare mp="$2"
	declare mount_options=""
	declare fstype_option=""
	declare fstype

	#
	# Get the filesystem type, if specified.
	#
	fstype_option=""
	fstype=${OCF_RESKEY_fstype}
	case "$fstype" in
	""|"[ 	]*")
		fstype=""
		;;
	*)	# found it
		fstype_option="-t $fstype"
		;;
	esac

	#
	# Get the mount options, if they exist.
	#
	mount_options=""
	opts=${OCF_RESKEY_options}
	case "$opts" in
	""|"[ 	]*")
		opts=""
		;;
	*)	# found it
		mount_options="-o $opts"
		;;
	esac

	#
	# Mount the device
	#
	ocf_log info "mounting $dev on $mp"
	ocf_log err "mount $fstype_option $mount_options $dev $mp"
	mount $fstype_option $mount_options "$dev" "$mp"
	ret_val=$?
	if [ $ret_val -ne 0 ]; then
		ocf_log err "\
'mount $fstype_option $mount_options $dev $mp' failed, error=$ret_val"
		return 1
	fi

	return 0
}


# Agent-specific actions to take after mounting
# (if required).
do_post_mount() {
	return 0
}


# Agent-specific actions to take before unmounting
# (if required)
do_pre_unmount() {
	return 0
}


# Agent-specific actions to take after umount succeeds
# (if required)
do_post_unmount() {
	return 0
}


# Agent-specific force unmount logic, if required
# return = 0 if successful, or nonzero if unsuccessful
# (unsuccessful = try harder)
do_force_unmount() {
	return 1
}


#
# start_filesystem
#
start_filesystem() {
	declare -i ret_val=$OCF_SUCCESS
	declare mp="${OCF_RESKEY_mountpoint}"
	declare dev=""			# device
	declare fstype=""
	declare opts=""
	declare mount_options=""

	#
	# Check if fstype is supported
	#
	verify_fstype
	case $? in
	$OCF_ERR_ARGS)
		ocf_log err "File system type $OCF_RESKEY_fstype not supported"
                return $OCF_ERR_ARGS
		;;
	*)
		;;
	esac

	#
	# Check if mount point was specified.  If not, no need to continue.
	#
	case "$mp" in
	""|"[ 	]*")		# nothing to mount
		return $OCF_SUCCESS
		;;
	/*)			# found it
		;;
	*)			# invalid format
			ocf_log err \
"start_filesystem: Invalid mount point format (must begin with a '/'): \'$mp\'"
		return $OCF_ERR_ARGS
		;;
	esac

	#
	# Get the device
	#
	real_device "$OCF_RESKEY_device"
	dev="$REAL_DEVICE"
	if [ -z "$dev" ]; then
			ocf_log err "\
start_filesystem: Could not match $OCF_RESKEY_device with a real device"
			return $OCF_ERR_ARGS
	fi

	#
	# Ensure we've got a valid directory
	#
	if [ -e "$mp" ]; then
		if ! [ -d "$mp" ]; then
			ocf_log err"\
start_filesystem: Mount point $mp exists but is not a directory"
			return $OCF_ERR_ARGS
		fi
	else
		ocf_log err "\
start_filesystem: Creating mount point $mp for device $dev"
		mkdir -p "$mp"
		ret_val=$?
		if [ $ret_val -ne 0 ]; then
			ocf_log err "\
start_filesystem: Unable to create $mp.  Error code: $ret_val"
			return $OCF_ERR_GENERIC
		fi
	fi

	#
	# See if the device is already mounted.
	#
	is_mounted "$dev" "$mp"
	case $? in
	$YES)		# already mounted
		ocf_log debug "$dev already mounted"
		return $OCF_SUCCESS
		;;
	$NO)		# not mounted, continue
		;;
	*)
		return $FAIL
		;;
	esac


	#
	# Make sure that neither the device nor the mount point are mounted
	# (i.e. they may be mounted in a different location).  The'mount_in_use'
	# function checks to see if either the device or mount point are in
	# use somewhere else on the system.
	#
	mount_in_use "$dev" "$mp"
	case $? in
	$YES)		# uh oh, someone is using the device or mount point
		ocf_log err "\
Cannot mount $dev on $mp, the device or mount point is already in use!"
		return $FAIL
		;;
	$NO)		# good, no one else is using it
		;;
	$FAIL)
		return $FAIL
		;;
	*)
		ocf_log err "Unknown return from mount_in_use"
		return $FAIL
		;;
	esac

	do_pre_mount
	case $? in
	0)
		;;
	1)
		return $OCF_ERR_GENERIC
		;;
	2)
		return $OCF_SUCCESS
		;;
	esac

	do_mount "$dev" "$mp"
	case $? in
	0)
		;;
	1)
		return $OCF_ERR_GENERIC
		;;
	2)
		return $OCF_SUCCESS
		;;
	esac

	do_post_mount
	case $? in
	0)
		;;
	1)
		return $OCF_ERR_GENERIC
		;;
	2)
		return $OCF_SUCCESS
		;;
	esac

	enable_fs_quotas "$opts" "$mp"

	return $OCF_SUCCESS
}


#
# stop_filesystem - unmount a file system; calls out to
#
stop_filesystem() {
	declare -i ret_val=0
	declare -i try
	declare -i sleep_time=5		# time between each umount failure
	declare umount_failed=""
	declare force_umount=""
	declare self_fence=""
	declare quotaopts=""

	#
	# Get the mount point, if it exists.  If not, no need to continue.
	#
	mp=${OCF_RESKEY_mountpoint}
	case "$mp" in
	""|"[ 	]*")		# nothing to mount
		return $OCF_SUCCESS
		;;
	/*)			# found it
		;;
	*)		# invalid format
			ocf_log err \
"stop_filesystem: Invalid mount point format (must begin with a '/'): \'$mp\'"
		return $FAIL
		;;
	esac

	#
	# Get the device
	#
	real_device "$OCF_RESKEY_device"
	dev="$REAL_DEVICE"
	if [ -z "$dev" ]; then
			ocf_log err "\
stop: Could not match $OCF_RESKEY_device with a real device"
			return $OCF_ERR_INSTALLED
	fi

	#
	# Get the force unmount setting if there is a mount point.
	#
	case ${OCF_RESKEY_force_unmount} in
        $YES_STR)	force_umount=$YES ;;
	on)		force_umount=$YES ;;
	true)		force_umount=$YES ;;
	1)		force_umount=$YES ;;
        *)		force_umount="" ;;
	esac

	#
	# self_fence _MUST_ be initialized before calling do_pre_unmount
	# The netfs agent depends on the self_fence variable.
	#
	case ${OCF_RESKEY_self_fence} in
        $YES_STR)	self_fence=$YES ;;
	on)		self_fence=$YES ;;
	true)		self_fence=$YES ;;
	1)		self_fence=$YES ;;
        *)		self_fence="" ;;
	esac

	do_pre_unmount
	case $? in
	0)
		;;
	1)
		return $OCF_ERR_GENERIC
		;;
	2)
		return $OCF_SUCCESS
		;;
	esac

	#
	# Preparations: sync, turn off quotas
	#
	sync

	quotaopts=$(quota_opts $OCF_RESKEY_options)
	if [ -n "$quotaopts" ]; then
		ocf_log debug "Turning off quotas for $mp"
		quotaoff -$quotaopts "$mp" &> /dev/null
	fi

	#
	# Unmount the device.
	#
	for try in 1 2 3; do
		if [ $try -ne 1 ]; then
			sleep $sleep_time
		fi

		is_mounted "$dev" "$mp"
		case $? in
		$NO)
			ocf_log info "$dev is not mounted"
			umount_failed=
			break
			;;
		$YES)	# fallthrough
			;;
		*)
			return $FAIL
			;;
		esac

		case ${OCF_RESKEY_no_unmount} in
			yes|YES|true|TRUE|YES|on|ON|1)
				ocf_log debug "Skipping umount on stop because of 'no_unmount' option"
				return $OCF_SUCCESS
				;;
			*) : ;;
		esac

		ocf_log info "unmounting $mp"
		umount "$mp"
		ret_val=$?
		# some versions of umount will exit with status 16 iff
		# the umount(2) succeeded but /etc/mtab could not be written.
		if  [ $ret_val -eq 0 -o $ret_val -eq 16 ]; then
			umount_failed=
			break
		fi

		ocf_log debug "umount failed: $ret_val"
		umount_failed=yes

		if [ -z "$force_umount" ]; then
			continue
		fi

		# Force unmount: try #1: send SIGTERM
		if [ $try -eq 1 ]; then
			# Try fs-specific force unmount, if provided
			do_force_unmount
			if [ $? -eq 0 ]; then
				# if this succeeds, we should be done
				continue
			fi

			ocf_log warning "Sending SIGTERM to processes on $mp"
			kill_procs_using_mount "$mp" "TERM"
			continue
		else
			ocf_log warning "Sending SIGKILL to processes on $mp"
			kill_procs_using_mount "$mp"

			if [ $? -eq 0 ]; then
				# someone is still accessing the mount, We've already sent
				# SIGTERM, now we've sent SIGKILL and are trying umount again.
				continue
			fi
			# mount has failed, and no one is accessing it.  There's
			# nothing left for us to try.
			break
		fi
	done # for

	do_post_unmount
	case $? in
	0)
		;;
	1)
		return $OCF_ERR_GENERIC
		;;
	2)
		return $OCF_SUCCESS
		;;
	esac

	if [ -n "$umount_failed" ]; then
		ocf_log err "'umount $mp' failed, error=$ret_val"

		if [ "$self_fence" ]; then
			ocf_log alert "umount failed - REBOOTING"
			sync
			reboot -fn
		fi
		return $OCF_ERR_GENERIC
	fi

	return $OCF_SUCCESS
}


do_start() {
	declare tries=0
	declare rv

	while [ $tries -lt 3 ]; do
		start_filesystem
		rv=$?
		if [ $rv -eq 0 ]; then
			return 0
		fi

		((tries++))
		sleep 3
	done
	return $rv
}


do_stop() {
	stop_filesystem
	return $?
}


do_monitor() {
	ocf_log debug "Checking fs \"$OCF_RESKEY_name\", Level $OCF_CHECK_LEVEL"

	#
	# Get the device
	#
	real_device "$OCF_RESKEY_device"
	dev="$REAL_DEVICE"
	if [ -z "$dev" ]; then
			ocf_log err "\
start_filesystem: Could not match $OCF_RESKEY_device with a real device"
			return $OCF_NOT_RUNNING
	fi

	is_mounted "$dev" "${OCF_RESKEY_mountpoint}"

	if [ $? -ne $YES ]; then
		ocf_log err "${OCF_RESOURCE_INSTANCE}: ${OCF_RESKEY_device} is not mounted on ${OCF_RESKEY_mountpoint}"
		return $OCF_NOT_RUNNING
	fi

	if [ "$OCF_RESKEY_quick_status" = "1" ]; then
		return 0
	fi

	is_alive "${OCF_RESKEY_mountpoint}"
	[ $? -eq $YES ] && return 0

	ocf_log err "fs:${OCF_RESKEY_name}: Mount point is not accessible!"
	return $OCF_ERR_GENERIC
}


do_restart() {
	stop_filesystem
	if [ $? -ne 0 ]; then
		return $OCF_ERR_GENERIC
	fi

	start_filesystem
	if [ $? -ne 0 ]; then
		return $OCF_ERR_GENERIC
	fi

	return 0
}


# MUST BE OVERRIDDEN
do_metadata() {
	return 1
}


do_validate() {
	return 1
}


main() {
	case $1 in
	start)
		do_start
		exit $?
		;;
	stop)
		do_stop
		exit $?
		;;
	status|monitor)
		do_monitor
		exit $?
		;;
	restart)
		do_restart
		exit $?
		;;
	meta-data)
		do_metadata
		exit $?
		;;
	validate-all)
		do_validate
		;;
	*)
		echo "usage: $0 {start|stop|status|monitor|restart|meta-data|validate-all}"
		exit $OCF_ERR_UNIMPLEMENTED
		;;
	esac
	exit 0
}

