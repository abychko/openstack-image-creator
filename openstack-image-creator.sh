#!/bin/bash -e
#
show_help(){
	echo "
Usage: $0 --distro <distro> --arch <arch> --release <release>
Where required are:
	<distro> is centos|debian|ubuntu
	<arch> is i386|(amd64|x86_64)
	<release> is depends on <distro>. it may be 6|7 for centos, wheezy|jessie|stretch for debian and trusty|xenial|yakkety|zesty for ubuntu

Additional params, not required:
	--imagesize <size>, default is 2G, for minimal image
	--remove-raw, default is no, to remove raw image after converting to compressed qcow2
	--root-password, default is auto-generated
	--cloud-user, default jenkins
	"
}
#
if [ $# -eq 0 ]; then
	show_help
	exit 1
fi
#
if [ $USER != root ]; then
	echo "* You must run this script as root to avoid erros!"
	exit 1
fi
#
DATE=$(date +%s)
DISTRO=debian
ARCH=amd64
RELEASE=jessie
IMAGESIZE=2G
PWGEN=$(which pwgen)
QEMU_IMG=$(which qemu-img)
ROOT_PASSWORD=$(pwgen -s 14 1)
REMOVE_RAW=no
INTERACTIVE=no
CLOUD_USER=jenkins
#
# Trying to parse the options passed to script
while [ $# -gt 1 ]; do
	case $1 in
		--help|-h )
			show_help
			exit 0
			;;
		--distro )
			export DISTRO=$2
			shift 2
			;;
		--arch )
			export ARCH=$2
			shift 2
			;;
		--release )
			export RELEASE=$2
			shift 2
			;;
		--imagesize )
			export IMAGESIZE=$2
			shift 2
			;;
		--root-password )
			export ROOT_PASSWORD=$2
			shift 2
			;;
		--remove-raw )
			export REMOVE_RAW=yes
			shift
			;;
		--cloud-user )
			export CLOUD_USER=$2
			shift 2
			;;
		*)
			echo "* Wrong param or value: $1"
			show_help
			exit 1
			;;
	esac
done
#
PARTED=$(which parted)
KPARTX=$(which kpartx)
FILENAME=${DISTRO}-${RELEASE}-${ARCH}_${DATE}
RAW_IMAGE=${FILENAME}.raw
QCOW2_IMAGE=${FILENAME}.qcow2
PASSWD_FILE=${FILENAME}.passwd
MOUNTDIR=$(mktemp -d -t ${FILENAME}.XXXXXX)
#
source $(dirname $0)/${DISTRO}.logic
#
#
#
cleanup(){
[ ! -d "${MOUNTDIR}" ] && return
  chroot ${MOUNTDIR} umount /proc || true
  chroot ${MOUNTDIR} umount /sys || true
  umount ${MOUNTDIR} || true
  rmdir  ${MOUNTDIR} || true
  kpartx -d ${RAW_IMAGE}
}
#
trap "cleanup" EXIT TERM INT
#
######################################
### Prepare the HDD (format, ext.) ###
######################################
${QEMU_IMG} create -f raw ${RAW_IMAGE} ${IMAGESIZE}
${PARTED} -s ${RAW_IMAGE} mklabel msdos
${PARTED} -s -a optimal ${RAW_IMAGE} mkpart primary ext4 0% 100%
${PARTED} -s ${RAW_IMAGE} set 1 boot on
install-mbr ${RAW_IMAGE}
RESULT_KPARTX=`kpartx -av ${RAW_IMAGE} 2>&1`
#
if echo "${RESULT_KPARTX}" | grep "^add map" ; then
  LOOP_DEVICE=`echo ${RESULT_KPARTX} | cut -d" " -f3`
  echo "kpartx mounted using: ${LOOP_DEVICE}"
else
  echo "It seems kpartx didn't mount the image correctly: exiting."
  exit 1
fi
#
##
mkfs.ext4 -O ^64bit /dev/mapper/${LOOP_DEVICE}
# No fsck because of X days without checks
tune2fs -i 0 /dev/mapper/${LOOP_DEVICE}
mount -o loop /dev/mapper/${LOOP_DEVICE} ${MOUNTDIR}
##
installBaseSystem
setLocale
createSourceList
upgradeSystem
adjustCloudSettings
configureFSTab
configureBoot
configureNetwork
cleanupSystem
setupConsole
echo "root password for ${QCOW2_IMAGE} is ${ROOT_PASSWORD}" > ${FILENAME}.passwd
chroot ${MOUNTDIR} sh -c "echo root:${ROOT_PASSWORD} | chpasswd"
chroot ${MOUNTDIR} adduser --gecos ${DISTRO}-cloud-user --disabled-password --quiet ${CLOUD_USER}
mkdir -p ${MOUNTDIR}/etc/sudoers.d
echo "${CLOUD_USER} ALL = NOPASSWD: ALL" > ${MOUNTDIR}/etc/sudoers.d/${CLOUD_USER}-cloud-init
chmod 0440 ${MOUNTDIR}/etc/sudoers.d/${CLOUD_USER}-cloud-init
#
chroot ${MOUNTDIR} umount /proc || true
umount ${MOUNTDIR}
rmdir  ${MOUNTDIR}
#
# Run FSCK
fsck.ext4 -f /dev/mapper/${LOOP_DEVICE} || true
kpartx -d ${RAW_IMAGE}
#
${QEMU_IMG} convert -c -f raw ${RAW_IMAGE} -O qcow2 ${QCOW2_IMAGE}
#
if [ ${REMOVE_RAW} = yes ]; then
	rm -fv ${RAW_IMAGE}
fi
#
