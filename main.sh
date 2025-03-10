#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -eEuo pipefail
IFS=$'\n\t'

g() {
    local cmd="$1"
    shift
    IFS=' '
    echo "::group::${cmd} $*"
    IFS=$'\n\t'
    "${cmd}" "$@"
}
retry() {
    for i in {1..10}; do
        if "$@"; then
            return 0
        else
            sleep "${i}"
        fi
    done
    "$@"
}
warn() {
    echo "::warning::$*"
}
_sudo() {
    if type -P sudo &>/dev/null; then
        sudo "$@"
    else
        "$@"
    fi
}
apt_update() {
    retry _sudo apt-get -o Acquire::Retries=10 -qq update
    apt_updated=1
}
apt_install() {
    if [[ -z "${apt_updated:-}" ]]; then
        apt_update
    fi
    retry _sudo apt-get -o Acquire::Retries=10 -o Dpkg::Use-Pty=0 install -y --no-install-recommends "$@"
}
dnf_install() {
    retry _sudo "${dnf}" install -y "$@"
}
zypper_install() {
    retry _sudo zypper install -y "$@"
}
pacman_install() {
    retry _sudo pacman -Sy --noconfirm "$@"
}
apk_install() {
    if type -P sudo &>/dev/null; then
        sudo apk --no-cache add "$@"
    elif type -P doas &>/dev/null; then
        doas apk --no-cache add "$@"
    else
        apk --no-cache add "$@"
    fi
}
sys_install() {
    case "${base_distro}" in
        debian) apt_install "$@" ;;
        fedora) dnf_install "$@" ;;
        suse) zypper_install "$@" ;;
        arch) pacman_install "$@" ;;
        alpine) apk_install "$@" ;;
    esac
}

wd=$(pwd)

base_distro=""
case "$(uname -s)" in
    Linux)
        host_os=linux
        if grep -q '^ID_LIKE=' /etc/os-release; then
            base_distro=$(grep '^ID_LIKE=' /etc/os-release | cut -d= -f2)
            case "${base_distro}" in
                *debian*) base_distro=debian ;;
                *fedora*) base_distro=fedora ;;
                *suse*) base_distro=suse ;;
                *arch*) base_distro=arch ;;
                *alpine*) base_distro=alpine ;;
            esac
        else
            base_distro=$(grep '^ID=' /etc/os-release | cut -d= -f2)
        fi
        case "${base_distro}" in
            fedora)
                dnf=dnf
                if ! type -P dnf &>/dev/null; then
                    if type -P microdnf &>/dev/null; then
                        # fedora-based distributions have "minimal" images that
                        # use microdnf instead of dnf.
                        dnf=microdnf
                    else
                        # If neither dnf nor microdnf is available, it is
                        # probably an RHEL7-based distribution that does not
                        # have dnf installed by default.
                        dnf=yum
                    fi
                fi
                ;;
        esac
        ;;
    Darwin) host_os=macos ;;
    MINGW* | MSYS* | CYGWIN* | Windows_NT) host_os=windows ;;
    *) bail "unrecognized OS type '$(uname -s)'" ;;
esac

if ! type -P git &>/dev/null; then
    case "${host_os}" in
        linux*)
            case "${base_distro}" in
                debian | fedora | suse | arch | alpine)
                    echo "::group::Install packages required for checkout (git)"
                    case "${base_distro}" in
                        debian) sys_install ca-certificates git ;;
                        *) sys_install git ;;
                    esac
                    echo "::endgroup::"
                    ;;
                *) warn "checkout-action requires git on non-Debian/Fedora/SUSE/Arch/Alpine-based Linux" ;;
            esac
            ;;
        macos) warn "checkout-action requires git on macOS" ;;
        windows) warn "checkout-action requires git on Windows" ;;
        *) bail "unsupported host OS '${host_os}'" ;;
    esac
fi

g git version

g git config --global --add safe.directory "${wd}"

# turn the detached message off
g git config --global advice.detachedHead false

g git init

GITHUB_PROTOCOL="${GITHUB_SERVER_URL%%://*}"
GITHUB_HOSTNAME="${GITHUB_SERVER_URL#*://}"
GIT_USERNAME="dummy"
GIT_CREDENTIALS="${GITHUB_PROTOCOL}://${GIT_USERNAME}:${INPUT_TOKEN}@${GITHUB_HOSTNAME}"

g git config --global credential.helper store

if ! grep -q "${GIT_CREDENTIALS}" ~/.git-credentials 2>/dev/null; then
    echo "${GIT_CREDENTIALS}" >> ~/.git-credentials
fi

g echo "Removing previously created refs, to avoid conflicts"
g git rev-parse --symbolic-full-name --verify --quiet HEAD || true

g echo "Cleaning the repository"
g git clean -ffdx

if [[ -n $(git show-ref HEAD) ]]; then
  g git reset --hard HEAD
fi

g echo "Disabling automatic garbage collection"
g git config --local gc.auto 0

if ! git remote -v | grep -qw origin; then
    g git remote add origin "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
fi

if [[ "${GITHUB_REF}" == "refs/heads/"* ]]; then
    branch="${GITHUB_REF#refs/heads/}"
    remote_ref="refs/remotes/origin/${branch}"
    g retry git fetch --no-tags --prune --no-recurse-submodules --depth=1 origin "+${GITHUB_SHA}:${remote_ref}"
    g retry git checkout --force -B "${branch}" "${remote_ref}"
else
    remote_ref="refs/remotes/pull${GITHUB_REF#refs/pull}"
    g git -c protocol.version=2 fetch --prune --progress --no-recurse-submodules origin '+refs/heads/*:refs/remotes/origin/*' "+${GITHUB_SHA}:${remote_ref}"
    g git checkout --progress --force "${remote_ref}"
fi

if [[ "${INPUT_PERSIST_CREDENTIALS}" != "true" ]]; then
    rm ~/.git-credentials
fi
