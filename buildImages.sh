#!/bin/bash -x
#
cd $(dirname $0)
#
# Centos Images
#
# 32 bit image
./openstack-image-creator.sh --with-jre --distro centos --arch i386 --release 6 --no-rebuild --remove-raw
#
for _release in 6 7; do
   ./openstack-image-creator.sh --with-jre --distro centos --arch x86_64 --release ${_release} --no-rebuild --remove-raw;
done
#
# Debian Images
for _release in wheezy jessie stretch; do
  for _arch in i386 amd64; do
    ./openstack-image-creator.sh --with-jre --distro debian --arch ${_arch} --release ${_release} --no-rebuild --remove-raw;
  done
done
#
# Ubuntu Images
for _release in artful trusty xenial zesty; do
  for _arch in i386 amd64; do
    ./openstack-image-creator.sh --with-jre --distro ubuntu --arch ${_arch} --release ${_release} --no-rebuild --remove-raw;
  done
done
#
