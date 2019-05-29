#!/bin/sh

HOSTNAME_VM="test_vm"
DISTRIB="stretch"
LVM_VG="work"
REPO_URL="http://repo.pet4.ru:9999/mirror.yandex.ru/debian"

DISK_SIZE="5G"
MEM_MB="512"
VCPUS="1"
INT_BR="br.0"

ROOTFS_LABEL="${HOSTNAME_VM}-root"
ROOT_DIR="/tmp/vm_install/${HOSTNAME_VM}"
INSTALL_DIR="${ROOT_DIR}/rootfs"
BOOT_DIR="${INSTALL_DIR}/boot"
VM_BOOT_DIR="/var/lib/libvirt/boot/${HOSTNAME_VM}"
DEVICE_NAME="/dev/${LVM_VG}/${ROOTFS_LABEL}"
MEM_KB="$((${MEM_MB}*1024))"

die_script(){
   echo "$1"
   exit 1
}

configuring_vm(){

  mount -B ${VM_BOOT_DIR} ${BOOT_DIR}

  # mount special fs
  chroot ${INSTALL_DIR} bash -c 'mount -t proc none /proc'
  
  if [ "$?" -ne "0" ]
  then
    echo 'ERROR: Can not mount proc.' 
    return 1
  fi

  chroot ${INSTALL_DIR} bash -c 'mount -t sysfs none /sys' 
  
  if [ "$?" -ne "0" ]
  then
    umount ${INSTALL_DIR}/proc
    echo 'ERROR: Can not mount sysfs.' 
    return 1
  fi

  printf "LABEL=${ROOTFS_LABEL} / ext4 defaults 0 0\n" >> ${INSTALL_DIR}/etc/fstab
  printf "boot /boot 9p defaults 0 0\n" >> ${INSTALL_DIR}/etc/fstab
  printf "${HOSTNAME_VM}" > ${INSTALL_DIR}/etc/hostname
  
  # change root password
  chroot ${INSTALL_DIR} bash -c 'echo -e "123\n123\n"|passwd'

  # configuring tzdata
  chroot ${INSTALL_DIR} bash -c 'ln -fs /usr/share/zoneinfo/Europe/Moscow /etc/localtime'
  chroot ${INSTALL_DIR} bash -c 'dpkg-reconfigure -f noninteractive tzdata'
  
  printf 'APT::Install-Recommends "0";\nAPT::Install-Suggests "0";\n' > ${INSTALL_DIR}/etc/apt/apt.conf.d/20recommends

  # configuring locale
  chroot ${INSTALL_DIR} bash -c 'apt-get install -y locales ssh sudo less bash-completion'

  if [ "$?" -ne "0" ]
  then
    umount ${INSTALL_DIR}/proc ${INSTALL_DIR}/sys
    echo 'ERROR: Can not install packages.'  
    return 1
  fi

  sed -i  's/^\s*#\s*\(ru_RU\.UTF-\?8.*\)/\1/i' ${INSTALL_DIR}/etc/locale.gen
  chroot ${INSTALL_DIR} bash -c 'locale-gen'
  printf 'LANG=C.UTF-8\n' >> ${INSTALL_DIR}/etc/default/locale

  printf 'do_symlinks = yes\nlink_in_boot = yes' >> ${INSTALL_DIR}/etc/kernel-img.conf

  # install kernel
  chroot ${INSTALL_DIR} bash -c 'apt-get update && apt-get install -y linux-image-amd64' 
  printf '9p\n9pnet\n9pnet_virtio' >>  ${INSTALL_DIR}/etc/initramfs-tools/modules
  chroot ${INSTALL_DIR} bash -c 'update-initramfs -u' 

  if [ "$?" -ne "0" ]
  then
    umount ${INSTALL_DIR}/proc ${INSTALL_DIR}/sys
    echo 'ERROR: Can not install kernel.'
    return 1
  fi

  return 0

}

echo "Create LVM for ${ROOTFS_LABEL}"
test "${ROOTFS_LABEL}" || die_script 'ERROR: LVM volume name is empty.'
vgs "${LVM_VG}" >/dev/null 2>&1 || die_script 'ERROR: Can not find vg.'
lvs "${LVM_VG}" 2>&1|grep "^\s\{1,\}${ROOTFS_LABEL}\s" && die_script 'ERROR: LVM volume already exist.'
lvcreate "${LVM_VG}" --name "${ROOTFS_LABEL}" -L ${DISK_SIZE} || die_script 'ERROR: Can not create lvm.'

echo "Create ext4 on ${DEVICE_NAME}"
mkfs.ext4 -L ${ROOTFS_LABEL} ${DEVICE_NAME}

[ -d "${INSTALL_DIR}" ] || mkdir -p "${INSTALL_DIR}"
[ -d "${VM_BOOT_DIR}" ] || mkdir -p "${VM_BOOT_DIR}"

echo "Install system on ${DEVICE_NAME}"
mount LABEL=${ROOTFS_LABEL} ${INSTALL_DIR} &&\
  debootstrap "${DISTRIB}" "${INSTALL_DIR}" "${REPO_URL}" &&\
  configuring_vm 

if [ "$?" -ne "0" ]
then
  umount ${INSTALL_DIR} 
  die_script 'ERROR: Can not configured vm.'
fi
 

umount ${INSTALL_DIR}/boot ${INSTALL_DIR}/proc ${INSTALL_DIR}/sys ${INSTALL_DIR}

virsh define /dev/stdin <<__EOF__
<domain type='kvm'>
  <name>${HOSTNAME_VM}</name>
  <memory unit='KiB'>${MEM_KB}</memory>
  <vcpu placement='static'>${VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='pc-i440fx-2.8'>hvm</type>
    <kernel>${VM_BOOT_DIR}/vmlinuz</kernel>
    <initrd>${VM_BOOT_DIR}/initrd.img</initrd>
    <cmdline>root=LABEL=${ROOTFS_LABEL} ro console=ttyS0 quiet</cmdline>
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
      <source dev='${DEVICE_NAME}'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='bridge'>
      <source bridge='${INT_BR}'/>
      <model type='virtio'/></interface>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <memballoon model='virtio'></memballoon>
    <filesystem type='mount' accessmode='mapped'>
      <driver type='path' wrpolicy='immediate'/>
      <source dir='${VM_BOOT_DIR}'/>
      <target dir='boot'/>
    </filesystem>
  </devices>
</domain>
__EOF__
