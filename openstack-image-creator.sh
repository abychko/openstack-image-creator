#!/bin/bash -xe
#
show_help(){
  echo "
Usage: $0 --distro <distro> --arch <arch> --release <release>
Where required are:
  <distro> is centos|debian|ubuntu
  <arch> is i386 |( amd64 | x86_64 )
  <release> is depends on <distro>. it may be:
    => 6 | 7 for centos,
    => wheezy | jessie | stretch for debian
    => trusty | xenial | yakkety | zesty | artful  for ubuntu

Additional params, not required:
  --with-jre, default is NO. Add JRE for Jenkins CI system
  --imagesize <size>, default is 1G, for minimal image
  --remove-raw, default is no, to remove raw image after converting to compressed qcow2
  --root-password, default is auto-generated
  --cloud-user, default virt-user
  --outdir <outdir>, default <distro>. Directory to store compressed qcow2 image and passwd file
  --openstack <yes|no>, default no. Create simple KVM image or adjust it for OpenStack
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
DATE=$(date +%Y%m%d)
DISTRO=debian
ARCH=amd64
RELEASE=buster
JRE=no
IMAGESIZE=2G # You may use k, M, G, T, P or E suffixes for kilobytes, megabytes, gigabytes, terabytes, petabytes and exabytes.
EXTLINUX=$(which extlinux)
PWGEN=$(which pwgen)
QEMU_IMG=$(which qemu-img)
LOSETUP=$(which losetup)
WGET=$(which wget)
ROOT_PASSWORD=$(pwgen -s 14 1)
REMOVE_RAW=no
INTERACTIVE=no
REBUILD=yes
CLOUD_USER=virt-user
BACKPORTS=yes
OPENSTACK=no
#
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
    --openstack )
      export OPENSTACK=yes
      shift
      ;;
    --outdir )
      export OUTDIR=$2
      shift 2
      ;;
    --with-jre )
      export JRE=yes
      shift
      ;;
    --no-rebuild )
      export REBUILD=no
      shift
      ;;
    --disable-backports )
      export BACKPORTS=no
      shift
      ;;
    *)
      echo "* Wrong param or value: $1"
      show_help
      exit 1
      ;;
  esac
done
#
# JRE-related. You need to export your server address
# including download location before the build
if [ -f script-params ]; then
  . script-params
fi
#
if [ -z "${JRE_DOWNLOAD_SERVER}" ]; then
  JRE_DOWNLOAD_SERVER="https://java.com" # ;)
fi
#
if [ -z ${JRE_VERSION} ]; then
  JRE_VERSION="8u241"
fi
#
if [ -z ${JRE_DIRNAME} ]; then
  JRE_DIRNAME="jre1.8.0_241"
fi
#
JRE_TARBALL="jre-${JRE_VERSION}-linux-${ARCH}.tar.gz"
#
if [ -n ${http_proxy} ]; then
  export http_proxy
fi
#
PARTED=$(which parted)
KPARTX=$(which kpartx)
FILENAME=${DISTRO}-${RELEASE}-${ARCH}-${DATE}
RAW_IMAGE=${FILENAME}.raw
QCOW2_IMAGE=${FILENAME}.qcow2
PASSWD_FILE=${FILENAME}.passwd
MOUNTDIR=$(mktemp -d -t ${FILENAME}.XXXXXX)
LIMITS=${MOUNTDIR}/etc/security/limits.d/99-${CLOUD_USER}.conf
SYSCTLVM=${MOUNTDIR}/etc/sysctl.d/99-vm-tuning.conf
#
configureLimits(){
  echo '* Setting global limits...'
  echo "${CLOUD_USER} soft nproc  65535" >> ${LIMITS}
  echo "${CLOUD_USER} hard nproc  65535" >> ${LIMITS}
  echo "${CLOUD_USER} soft nofile 1048576" >> ${LIMITS}
  echo "${CLOUD_USER} hard nofile 1048576" >> ${LIMITS}
  #
  echo 'vm.dirty_ratio = 6'             >> ${SYSCTLVM}
  echo 'vm.dirty_background_ratio = 3'  >> ${SYSCTLVM}
  echo 'vm.vfs_cache_pressure = 50'     >> ${SYSCTLVM}
}
#
if [ -z "${OUTDIR}" ]; then
  OUTDIR=IMAGES/${DATE}
fi
#
if [ ${REBUILD} = no ]; then
  if [ -f ${OUTDIR}/${QCOW2_IMAGE} ]; then
    echo "* Image is built already, exiting"
    exit 0
  fi
fi
#
. $(dirname $0)/${DISTRO}.logic
#
cleanup(){
[ ! -d "${MOUNTDIR}" ] && return
  umount -R ${MOUNTDIR}/proc || true
  umount -R ${MOUNTDIR}/sys || true
  umount -R ${MOUNTDIR}/dev || true
  umount -R ${MOUNTDIR} || true
  rmdir  ${MOUNTDIR} || true
  kpartx -d ${RAW_IMAGE}
}
#
trap "cleanup" EXIT TERM INT
#
######################################
### Prepare the HDD (format, ext.) ###
######################################
#
rm -fv ${RAW_IMAGE} ${OUTDIR}/${QCOW2_IMAGE}
#
${QEMU_IMG} create -f raw ${RAW_IMAGE} ${IMAGESIZE}
${PARTED} -s ${RAW_IMAGE} mklabel msdos
${PARTED} -s -a optimal ${RAW_IMAGE} mkpart primary ext4 0% 100%
${PARTED} -s ${RAW_IMAGE} set 1 boot on
install-mbr --force ${RAW_IMAGE}
RESULT_KPARTX=`kpartx -av ${RAW_IMAGE} 2>&1`
#
if echo "${RESULT_KPARTX}" | grep "^add map" ; then
  LOOP_DEVICE=`echo ${RESULT_KPARTX} | cut -d" " -f3`
  echo "kpartx mounted using: ${LOOP_DEVICE}"
else
  echo "It seems kpartx didn't mount the image correctly, exiting."
  exit 1
fi
#
# wait until loop device will appear
sleep 5
##
mkfs.ext4 -O ^64bit /dev/mapper/${LOOP_DEVICE}
tune2fs -c 0 -LROOT /dev/mapper/${LOOP_DEVICE}
mount -o loop /dev/mapper/${LOOP_DEVICE} ${MOUNTDIR}
export UUID=$(blkid -o value -s UUID /dev/mapper/${LOOP_DEVICE})
mkdir -p ${MOUNTDIR}/{proc,sys,dev,etc}
##
if [ ${DISTRO} != centos ]; then
  installBaseSystem
fi
# mount /proc, /dev, /sys
mount -t proc /proc ${MOUNTDIR}/proc
mount --rbind /sys ${MOUNTDIR}/sys
mount --make-rslave ${MOUNTDIR}/sys
mount --rbind /dev ${MOUNTDIR}/dev
mount --make-rslave ${MOUNTDIR}/dev
#
cat /etc/resolv.conf > ${MOUNTDIR}/etc/resolv.conf
#
if [ ${DISTRO} = centos ]; then
  installBaseSystem
fi
#
chroot ${MOUNTDIR} rm -f /etc/mtab
chroot ${MOUNTDIR} ln -s /proc/mounts /etc/mtab
#
configureFSTab
setLocale
createRepositories
upgradeSystem
adjustCloudSettings
createCloudUser
configureLimits
configureBoot
#
configureNetwork
cleanupSystem
setupConsole
configureModules
setHostname
##
# Install JRE if requested
if [ ${JRE} = yes ]; then
  if [ ! -f ${JRE_TARBALL} ]; then
    ${WGET} ${JRE_DOWNLOAD_SERVER}/${JRE_TARBALL}
  fi
  tar -xzf ${JRE_TARBALL} -C ${MOUNTDIR}/usr/local
  pushd ${MOUNTDIR}/usr/local
  ln -s ${JRE_DIRNAME} java
  popd
fi
#
##
echo "* saving ROOT password to ${FILENAME}.passwd..."
echo "Autogenerated root password for ${QCOW2_IMAGE} is ${ROOT_PASSWORD}" > ${FILENAME}.passwd
echo "* setting ROOT password ..."
chroot ${MOUNTDIR} bash -c "echo root:${ROOT_PASSWORD} | chpasswd"

echo "* adding sudoers file for ${CLOUD_USER}..."
mkdir -p ${MOUNTDIR}/etc/sudoers.d
echo "${CLOUD_USER} ALL = NOPASSWD: ALL" > ${MOUNTDIR}/etc/sudoers.d/${CLOUD_USER}-cloud-init
chmod 0440 ${MOUNTDIR}/etc/sudoers.d/${CLOUD_USER}-cloud-init
chroot ${MOUNTDIR} chown -R ${CLOUD_USER} /home/${CLOUD_USER}
#
# Fill up free space with zeroes
echo "* filling up the free image space with zeroes ..."
dd if=/dev/zero of=${MOUNTDIR}/zerofile status=progress || true
rm -fv ${MOUNTDIR}/zerofile
#
sync && sync
#
# KILL chroot'ed processes
PIDS=""
for ROOT in /proc/*/root; do
  LINK=$(readlink $ROOT)
  if [ "x$LINK" != "x" ]; then
    if [ "x${LINK:0:${#MOUNTDIR}}" = "x${MOUNTDIR}" ]; then
      # this process is in the chroot...
      PID=$(basename $(dirname "$ROOT"))
      echo "* Need to kill pid ${PID} in chroot ..."
      PIDS="${PIDS} ${PID}"
    fi
  fi
done
#
if [ -n "${PIDS}" ]; then
  kill -9 ${PIDS}
fi
#
# some kind of workaround
#chroot ${MOUNTDIR} service rsyslog stop
sleep 5
#
umount -R ${MOUNTDIR}/dev  || true
umount -R ${MOUNTDIR}/sys  || true
umount -R ${MOUNTDIR}/proc || true
umount -R ${MOUNTDIR}
#
echo "* Sleeping a bit..."
sleep 5
#
echo "* Removing temp installation directory ..."
rmdir ${MOUNTDIR}
#
# Run FSCK
echo "* Running fsck on /dev/mapper/${LOOP_DEVICE} ..."
fsck.ext4 -f -y /dev/mapper/${LOOP_DEVICE} || true
#
echo "* Sleeping a bit..."
sleep 5
#
echo "* Detaching ${RAW_IMAGE} ..."
kpartx -dv ${RAW_IMAGE}
#
echo "* Converting RAW image ${RAW_IMAGE} to QCOW2 ..."
${QEMU_IMG} convert -c -f raw ${RAW_IMAGE} -O qcow2 ${QCOW2_IMAGE}
#
#
mkdir -p ${OUTDIR}
mv -fv ${FILENAME}.qcow2 ${FILENAME}.passwd ${OUTDIR}
#
if [ ${REMOVE_RAW} = yes ]; then
  echo "* removing RAW image ${RAW_IMAGE} ..."
  rm -fv ${RAW_IMAGE}
fi
#
echo "* Image done - $(readlink -f ${OUTDIR}/${QCOW2_IMAGE})"
echo "* Password for $(readlink -f ${OUTDIR}/${QCOW2_IMAGE}) is saved to ${OUTDIR}/${FILENAME}.passwd"
#
