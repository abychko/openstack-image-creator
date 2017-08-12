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
  --outdir <outdir>, default <distro>. Directory to store compressed qcow2 image and passwd file
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
cd $(readlink -f $(dirname $0))
#
DATE=$(date +%s)
DISTRO=debian
ARCH=amd64
RELEASE=jessie
IMAGESIZE=2 #G
PWGEN=$(which pwgen)
QEMU_IMG=$(which qemu-img)
LOSETUP=$(which losetup)
ROOT_PASSWORD=$(pwgen -s 14 1)
REMOVE_RAW=no
INTERACTIVE=no
CLOUD_USER=jenkins
#
# Trying to parse the options passed to script
while [ $# -gt 0 ]; do
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
    --outdir )
      export OUTDIR=$2
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
OUTDIR=${DISTRO}
#
. $(dirname $0)/${DISTRO}.logic
#
cleanup(){
[ ! -d "${MOUNTDIR}" ] && return
  umount ${MOUNTDIR}/proc || true
  umount ${MOUNTDIR}/sys || true
  umount ${MOUNTDIR}/dev || true
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
${QEMU_IMG} create -f raw ${RAW_IMAGE} ${IMAGESIZE}G
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
tune2fs -c 0 /dev/mapper/${LOOP_DEVICE}
mount -o loop /dev/mapper/${LOOP_DEVICE} ${MOUNTDIR}
##
installBaseSystem
#
# mount /proc, /dev, /sys
mount -t proc /proc ${MOUNTDIR}/proc
mount --rbind /sys ${MOUNTDIR}/sys
mount --make-rslave ${MOUNTDIR}/sys
mount --rbind /dev ${MOUNTDIR}/dev
mount --make-rslave ${MOUNTDIR}/dev
chroot ${MOUNTDIR} ln -s /proc/mounts /etc/mtab
#
configureFSTab
setLocale
createSourceList
upgradeSystem
adjustCloudSettings
configureBoot
configureNetwork
cleanupSystem
setupConsole
configureModules
setHostname
##
echo "* saving ROOT password to ${FILENAME}.passwd..."
echo "Autogenerated root password for ${QCOW2_IMAGE} is ${ROOT_PASSWORD}" > ${FILENAME}.passwd
echo "* setting ROOT password ..."
chroot ${MOUNTDIR} bash -c "echo root:${ROOT_PASSWORD} | chpasswd"
echo "* adding cloud user ${CLOUD_USER} ..."
chroot ${MOUNTDIR} adduser --gecos ${DISTRO}-cloud-user --disabled-password --quiet ${CLOUD_USER}
echo "* adding sudoers file for ${CLOUD_USER}..."
mkdir -p ${MOUNTDIR}/etc/sudoers.d
echo "${CLOUD_USER} ALL = NOPASSWD: ALL" > ${MOUNTDIR}/etc/sudoers.d/${CLOUD_USER}-cloud-init
chmod 0440 ${MOUNTDIR}/etc/sudoers.d/${CLOUD_USER}-cloud-init
#
# Fill up free space with zeroes
echo "* filling up the free image space with zeroes ..."
dd if=/dev/zero of=${MOUNTDIR}/zerofile || true
rm -fv ${MOUNTDIR}/zerofile
#
sync && sync
# KILL chroot'ed processes
for ROOT in /proc/*/root; do
  LINK=$(readlink $ROOT)
  if [ "x$LINK" != "x" ]; then
    if [ "x${LINK:0:${#MOUNTDIR}}" = "x${MOUNTDIR}" ]; then
      # this process is in the chroot...
      PID=$(basename $(dirname "$ROOT"))
      echo "* killing pid $PID in chroot ..."
      kill -TERM "$PID"
    fi
  fi
done
#
for DIR in $(mount | grep ${MOUNTDIR} | tac | awk '{print $3}'); do
  echo "* unmounting ${DIR} ..."
  umount ${DIR}
done
#
echo "* removing temp installation directory ..."
rmdir ${MOUNTDIR}
#
# Run FSCK
echo "* running fsck on /dev/mapper/${LOOP_DEVICE} ..."
fsck.ext4 -f -y /dev/mapper/${LOOP_DEVICE} || true
kpartx -d ${RAW_IMAGE}
#
echo "* converting RAW image ${RAW_IMAGE} to QCOW2 ..."
${QEMU_IMG} convert -c -f raw ${RAW_IMAGE} -O qcow2 ${QCOW2_IMAGE}
#
#MNTDEVICE=$(${LOSETUP} --all | grep ${RAW_IMAGE} | awk -F':' '{print $1}')
#echo "* removing loop device ${MNTDEVICE} ..."
#${LOSETUP} -v --detach ${MNTDEVICE}
#
mkdir -p ${OUTDIR}
mv -fv ${FILENAME}.qcow2 ${FILENAME}.passwd ${OUTDIR}
#
if [ ${REMOVE_RAW} = yes ]; then
  echo "* removing RAW image ${RAW_IMAGE} ..."
  rm -fv ${RAW_IMAGE}
fi
#
echo "* Image done - ${OUTDIR}/${QCOW2_IMAGE}"
echo "* Password for ${QCOW2_IMAGE} is saved to ${OUTDIR}/${FILENAME}.passwd"
#
