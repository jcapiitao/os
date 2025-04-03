#!/bin/bash
set -euo pipefail

IGNITION_CONFIG=/run/ignition.json
# https://github.com/openshift/machine-config-operator/pull/868
MACHINE_CONFIG_ENCAPSULATED=/etc/ignition-machine-config-encapsulated.json

main() {
    mode=$1; shift
    case "$mode" in
        firstboot) firstboot;;
        *) fatal "Invalid mode $mode";;
    esac
}

firstboot() {
    if [ "$(</proc/sys/crypto/fips_enabled)" -eq 1 ]; then
        noop "FIPS mode is enabled."
    fi

    # Make sure the Ignition messages made it to disk before querying
    # https://bugzilla.redhat.com/show_bug.cgi?id=1862957
    journalctl --sync

    # See https://github.com/coreos/fedora-coreos-config/commit/65de5e0f1676fa20537caa781937c1632eee5718
    # And see https://github.com/coreos/ignition/pull/958 for the MESSAGE_ID source.
    ign_usercfg_msg=$(journalctl -q MESSAGE_ID=57124006b5c94805b77ce473e92a8aeb IGNITION_CONFIG_TYPE=user)
    if [ -z "${ign_usercfg_msg}" ]; then
        noop "No Ignition config provided."
    fi
    if [ ! -f "${IGNITION_CONFIG}" ]; then
        fatal "Missing ${IGNITION_CONFIG}"
    fi

    local tmp=/run/rhcos-fips
    local tmpsysroot="${tmp}/sysroot"
    coreos-dummy-ignition-files-run "${tmp}" "${IGNITION_CONFIG}" "${MACHINE_CONFIG_ENCAPSULATED}"

    if [ ! -f "${tmpsysroot}/${MACHINE_CONFIG_ENCAPSULATED}" ]; then
        noop "No ${MACHINE_CONFIG_ENCAPSULATED} found in Ignition config"
    fi

    echo "Found ${MACHINE_CONFIG_ENCAPSULATED} in Ignition config"

    # don't use -e here to distinguish between false/null
    case $(jq .spec.fips "${tmpsysroot}/${MACHINE_CONFIG_ENCAPSULATED}") in
        false) noop "FIPS mode not requested";;
        true) ;;
        *)
            cat "${tmpsysroot}/${MACHINE_CONFIG_ENCAPSULATED}"
            fatal "Missing/malformed FIPS field"
            ;;
    esac

    echo "FIPS mode required; updating BLS entry"

    rdcore kargs --boot-device /dev/disk/by-label/boot \
        --append fips=1 --append boot=LABEL=boot

    echo "Scheduling reboot"
    # Write to /run/coreos-kargs-reboot to inform the reboot service so we
    # can apply both kernel arguments & FIPS without multiple reboots
    > /run/coreos-kargs-reboot
}

noop() {
    echo "$@"
    exit 0
}

fatal() {
    echo "$@"
    exit 1
}

main "$@"
