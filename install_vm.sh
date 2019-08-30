#!/bin/sh


CONF=config_vm
VG=test
VMNAME=test
DIST=buster
REPO=http://httpredir.debian.org/debian
FS=ext4
DISK=2G
MEM=256
BR=br
CPUS=1
CHIPSET=pc-i440fx-2.8

die_script(){
   echo "$1"
   exit 1
}

test -e $CONF && . ./$CONF || die_script "ERROR: can not find $CONF."
LABEL="$VMNAME-root"
DIR="/tmp/vm_install/$VMNAME"
LVM="/dev/$VG/$LABEL"
DEV="/tmp/virtual_disk"

configuring_vm(){
  mknod $DIR$DEV b 7 25
  printf "LABEL=$LABEL / $FS defaults 0 0\n" >> $DIR/etc/fstab
  printf "$VMNAME" > $DIR/etc/hostname
  sed -i 's/^\s*#\s*\(ru_RU\.UTF-\?8.*\)/\1/i' $DIR/etc/locale.gen
  printf 'LANG=C.UTF-8\n' > $DIR/etc/default/locale
  printf 'APT::Install-Recommends "0";\n' > $DIR/etc/apt/apt.conf.d/20recommends
  chroot $DIR bash -c 'mount -t proc none /proc'
  chroot $DIR bash -c 'passwd -d root'
  chroot $DIR bash -c 'ln -fs /usr/share/zoneinfo/Europe/Moscow /etc/localtime'
  chroot $DIR bash -c 'dpkg-reconfigure -f noninteractive tzdata'
  chroot $DIR bash -c 'locale-gen'
  sed -i '/GRUB_CMDLINE_LINUX_DEFAULT/s/quiet/quiet console=ttyS0/' $DIR/etc/default/grub
  printf 'GRUB_TERMINAL="serial console"\n' >> $DIR/etc/default/grub
  printf 'GRUB_SERIAL_COMMAND="serial --unit=0 --speed=115200 --word=8 --parity=no --stop=1"\n' >> $DIR/etc/default/grub
chroot $DIR bash -c 'update-grub'
  sed -i "s!$DEV!LABEL=$LABEL!" "$DIR/boot/grub/grub.cfg"
  chroot $DIR bash -c "grub-install --force $DEV" || return 1
  rm $DIR$DEV
  return 0
}

echo "Create LVM for $LABEL"
test $LABEL || die_script 'ERROR: LVM volume name is empty.'
test -e $DEV && die_script "ERROR: $DEV file exist."
vgs $VG >/dev/null 2>&1 || die_script 'ERROR: Can not find vg.'
lvs $VG 2>&1|grep "^\s\{1,\}$LABEL\s" && die_script 'ERROR: LVM volume already exist.'

lvcreate $VG --name $LABEL -L $DISK || die_script 'ERROR: Can not create lvm.'
mknod $DEV b 7 25 
losetup $DEV $LVM
mkfs -t $FS -L $LABEL $DEV

test -d "$DIR" || mkdir -p "$DIR"

mount $DEV $DIR &&\
  debootstrap --include="locales,linux-image-amd64,grub2" $DIST $DIR $REPO &&\
  configuring_vm || ERR=1

umount $DIR/proc $DIR && losetup -d $DEV && rm $DEV
test $ERR && die_script 'ERROR: Can not configured vm.'

virsh define /dev/stdin <<__EOF__
<domain type='kvm'>
  <name>$VMNAME</name>
  <memory unit='KiB'>$(($MEM*1024))</memory>
  <vcpu placement='static'>$CPUS</vcpu>
  <os>
    <type arch='x86_64' machine='$CHIPSET'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
    <vmport state='off'/> 
  </features>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/bin/kvm</emulator>
    <disk type='block' device='disk'>
      <source dev='$LVM'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='bridge'>
      <source bridge='$BR'/>
      <model type='virtio'/></interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <memballoon model='virtio'></memballoon>
  </devices>
</domain>
__EOF__
