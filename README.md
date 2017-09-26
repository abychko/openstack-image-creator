# openstack-image-creator
Shell script to create images for OpenStack, inspired by https://github.com/marekruzicka/openstack-debian-image

# Installing dependencies (assuming Ubuntu Xenial 16.04 amd64)
* $ sudo apt-get update
* $ export DEBIAN_FRONTEND=noninteractive
* $ sudo apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"  dist-upgrade
* $ sudo apt-get -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"  install debootstrap lynx rpm yum pwgen qemu-utils parted kpartx mbr 
* $

# Example, build Centos images
```
sudo bash -x ./openstack-image-creator.sh --distro centos --arch i386 --release 6 --remove-raw --outdir IMAGES
sudo bash -x ./openstack-image-creator.sh --distro centos --arch x86_64 --release 6 --remove-raw --outdir IMAGES
sudo bash -x ./openstack-image-creator.sh --distro centos --arch x86_64 --release 7 --remove-raw --outdir IMAGES
```
# Example, build Debian images
```
for _release in wheezy jessie stretch; do
  for _arch in i386 amd64; do
    sudo bash -x ./openstack-image-creator.sh --distro debian --arch ${_arch} --release ${_release} --remove-raw --outdir IMAGES
  done
done
```
# Example, build Ubuntu images
```
for _release in trusty xenial yakkety zesty artful; do
	for _arch in i386 amd64; do
		sudo bash -x ./openstack-image-creator.sh --distro ubuntu --arch ${_arch} --release ${_release} --remove-raw --outdir IMAGES
	done
done
```
