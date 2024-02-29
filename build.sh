#!/usr/bin/env bash

set -eu

# path details
declare -r CACHE_DIR="${HOME}/.devbox-cache"
declare -r DATA_DIR="${PWD}/_data"
declare -r SCRIPT_DIR="${PWD}/_scripts"

# image details
declare -r IMAGE_DISTRO="jammy"
declare -r IMAGE_NAME="${IMAGE_DISTRO}-server-cloudimg-amd64.img"
declare -r IMAGE_SIZE="100G"

# VM details
declare -r CPU="${CPU:-max}"
declare -r ACCEL="${ACCEL:-hvf}"
declare -ir CORES="${CORES:-4}"
declare -ir MEMORY="$((CORES * 2048))"

# git details
read -r GIT_USER < <(git config --global --get user.name); readonly GIT_USER
read -r GIT_MAIL < <(git config --global --get user.email); readonly GIT_MAIL

# dev environment details
declare -r GO_VERSION="go1.20.3"




find_ssh_open_port() {
  declare -ir start_port=2222
  declare -ir max_port=3333

  for ((i=start_port;i<max_port;i++)); do
    if grep -rnq -e "Port ${i}" $HOME/.ssh/config; then
      continue
    fi

    if netstat -taln | grep "${i}"; then
      continue
    fi

    echo "${i}"
    return
  done

  echo "No available port found"
  exit 1
}



setup_image() {
  mkdir -p "${CACHE_DIR}"
  # Setup cache
  if [[ ! -f "${CACHE_DIR}/${IMAGE_NAME}" ]]; then
    echo "Downloading ubuntu image"
    curl \
      "https://cloud-images.ubuntu.com/focal/current/${IMAGE_NAME}" \
      --output "${CACHE_DIR}/${IMAGE_NAME}"
  fi

  # Copy from cache and resize
  if [[ ! -f "${DATA_DIR}/${IMAGE_NAME}" ]]; then
    echo "Copying image"
    cp "${CACHE_DIR}/${IMAGE_NAME}" "${DATA_DIR}/${IMAGE_NAME}"
    qemu-img resize "${DATA_DIR}/${IMAGE_NAME}" "${IMAGE_SIZE}"
  fi
}




setup_cloud_config() {
  cd "${DATA_DIR}" || exit 1

  if [[ -f "cidata.iso" ]]; then
    return 0
  fi

  if [[ -z "${GIT_USER}" ]]; then
    echo "missing git user, exiting..."
    exit 1
  fi

  if [[ -z "${GIT_MAIL}" ]]; then
    echo "missing git mail, exiting..."
    exit 1
  fi

  if [[ -z "${GIT_TOKEN}" ]]; then
    echo "missing git token, exiting..."
    exit 1
  fi


  ssh-keygen -b 2048 -t rsa -f "${GUEST_NAME}" -P ""
  read -r public_key < <(cat "${GUEST_NAME}.pub")
  chmod 600 "${GUEST_NAME}"


  cat <<EOF > meta-data
instance-id: "${GUEST_NAME}"
local-hostname: "${GUEST_NAME}"
EOF

  cat <<EOF > user-data
#cloud-config
debug: true
packages_upgrade: true
packages_update: true
disable_root: false

apt:
  sources:
    docker.list:
      source: deb [arch=amd64] https://download.docker.com/linux/ubuntu \$RELEASE stable
      keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88

packages:
  - curl
  - git
  - lsof
  - docker-ce
  - docker-ce-cli
  - containerd.io
  - qemu-kvm
  - bridge-utils
  - iputils
  - iproute2
  - net-tools
  - netcat
  - socat
  - tcpdump
  - tcputils
  - traceroute

groups:
  - docker

system_info:
  default_user:
    groups: [ docker ]

power_state:
    delay: now
    mode: poweroff
    message: Powering off
    timeout: 2

users:
  - name: root
    password: ubuntu
    shell: /bin/bash
    ssh-authorized-keys:
      - ${public_key}

write_files:
- path: /etc/sysctl.conf
  content: |
    net.ipv4.ip_forward=1
  append: true
- path: /etc/modules
  content: |
    tun
    loop
    dummy
  append: true
- path: /root/.gitconfig
  content: |
    [user]
      name = ${GIT_USER}
      email = ${GIT_MAIL}
    [core]
      editor = vim
    [url "https://${GIT_TOKEN}:x-oauth-basic@github.com/"]
      insteadOf = https://github.com/
  append: true
- path: /root/.bash_profile
  content: |
    export TERM="xterm-256color"
    export EDITOR="vim"

    alias vi="vim"
    alias ls="ls -FGlAp --color"

    GOROOT=/usr/local/go
    GOPATH=/root/go
    GOBIN=\${GOPATH}/bin
    PATH="\${GOPATH}:\${GOBIN}:\${GOROOT}/bin:\${PATH}"
  append: true

runcmd:
  - curl -L https://dl.google.com/go/${GO_VERSION}.linux-amd64.tar.gz | tar -C /usr/local/ -xzf -
EOF

  mkisofs -output cidata.iso -volid cidata -joliet -rock user-data meta-data
}




setup_scripts() {
  cat <<EOF > "${SCRIPT_DIR}/run.sh"
#!/usr/bin/env bash

if [[ -f ${DATA_DIR}/${GUEST_NAME}.pid ]]; then
  echo "Already running with process id: \$(cat ${DATA_DIR}/${GUEST_NAME}.pid)"; exit 0
fi

declare -a args=("\${@}")

# If nested kvm is required, the follow paramters can be switched out/added to
# the arguments at the cost of performece:
#
#   -cpu qemu64
#   -machine type=q35,tcg
#   -enable-kvm

args+=("-cpu" "${CPU}")
args+=("-smp" "${CORES}")
args+=("-m" "${MEMORY}")
args+=("-machine" "type=q35,accel=${ACCEL}")
args+=("-hda" "${DATA_DIR}/${IMAGE_NAME}")
args+=("-netdev" "user,id=net0,hostfwd=tcp::${SSH_ACCESS_PORT}-:22")
args+=("-device" "e1000,netdev=net0")
args+=("-pidfile" "${DATA_DIR}/${GUEST_NAME}.pid")

if [[ "\${args[*]}" != *"-nographic"* ]]; then
  args+=("-daemonize" "-display" "none")
fi

qemu-system-x86_64 "\${args[@]}"

EOF
  chmod +x "${SCRIPT_DIR}/run.sh"




  cat << EOF > "${SCRIPT_DIR}/login.sh"
#!/usr/bin/env bash

ssh -l root -p "${SSH_ACCESS_PORT}" -o "StrictHostKeyChecking=no" -o "IdentitiesOnly=yes" -i "${DATA_DIR}/${GUEST_NAME}" localhost
EOF
  chmod +x "${SCRIPT_DIR}/login.sh"




  cat << EOF > "${SCRIPT_DIR}/kill.sh"
#!/usr/bin/env bash

trap 'rm -f "${DATA_DIR}/${GUEST_NAME}.pid"' EXIT

if ! read -r pid < <(cat "${DATA_DIR}/${GUEST_NAME}.pid") 2>/dev/null; then
  echo "pidfile not found, exiting..."; exit 1
fi

if ! pgrep qemu-system-x86_64 | grep -q "\${pid}"; then
  echo "pid: \${pid} not found, exiting..."; exit 1
fi

echo "Killing qemu-system-x86_64 process: \${pid}"
kill -9 "\${pid}"
EOF
  chmod +x "${SCRIPT_DIR}/kill.sh"
}




main() {
  echo "* Checking dependencies..."
  for dep in mkisofs qemu-system-x86_64 qemu-img git pgrep; do
    if ! command -v "${dep}" >/dev/null; then
      echo "Missing dependency: ${dep}"
      exit 1
    fi
  done
  # if scripts are re-generated, read guest name form configuration
  if read -r guest < <(grep "label:" "${DATA_DIR}/guest_info" 2>/dev/null | awk '{print $2}'); then
    declare -rg GUEST_NAME="${guest}"
  else
    declare -rg GUEST_NAME="${1:?"Missing required argument"}"
  fi

  if read -r git_token < <(grep "git-token:" "${DATA_DIR}/guest_info" 2>/dev/null | awk '{print $2}'); then
    declare -rg GIT_TOKEN="${git_token}"
  else
    declare -rg GIT_TOKEN="${2:?"Missing required argument"}"
  fi

  if read -r ssh_port < <(grep "Port:" "${DATA_DIR}/guest_info" 2>/dev/null | awk '{print $2}'); then
    declare -irg SSH_ACCESS_PORT="${ssh_port}"
  elif read -r ssh_port < <(find_open_ssh_port 2>/dev/null); then
    declare -irg SSH_ACCESS_PORT="${ssh_port}"
  else
    echo "Failed to find an open port to use for ssh access"
    exit 1
  fi


  mkdir -p "${DATA_DIR}"
  mkdir -p "${SCRIPT_DIR}"
  # Always generate the scripts so values like ssh access port or guest specs
  # can be changed
  echo "* Generating scripts"
  setup_scripts

  if [[ ! -f "${DATA_DIR}/created" ]]; then
    set +x
    echo "* Creating disk image"
    setup_image

    echo "* Generating metadata"
    ( setup_cloud_config > /dev/null )

    echo "* Building image"
    "${SCRIPT_DIR}/run.sh" "-cdrom" "${DATA_DIR}/cidata.iso" "-nographic"

    date > "${DATA_DIR}/created"
    set -x
  fi
}

main "${@}" && {
  cat << EOF > "${DATA_DIR}/guest_info"
qemu:
  image file:   ${IMAGE_NAME}
  disk size:    ${IMAGE_SIZE}
  cpu:          ${CPU}
  accel:        ${ACCEL}
  cores:        ${CORES}
  memory:       ${MEMORY}
-
cloud-init:
  label:        ${GUEST_NAME}
  git-user:     ${GIT_USER}
  git-mail:     ${GIT_MAIL}
  git-token:    ${GIT_TOKEN}
-
ssh-config:
${GUEST_NAME}
  Hostname localhost
  User root
  Port ${SSH_ACCESS_PORT}
  IdentitiesOnly yes
  StrictHostKeyChecking no
  IdentityFile ${DATA_DIR}/${GUEST_NAME}
EOF

  cat "${DATA_DIR}/guest_info"
}
