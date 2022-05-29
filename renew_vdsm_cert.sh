#!/usr/bin/bash

host_to_renew=$1
if [ -z "${host_to_renew}" ]; then
  echo "Usage: $0 host_to_renew"
  echo "Example: $0 my.host.example.com"
  exit 255
fi
host_vdsmkey=/tmp/${host_to_renew}.vdsmkey.pem
host_csr=/tmp/${host_to_renew}.vdsm.csr
host_new_cert=/tmp/${host_to_renew}.vdsm.cer

function cleanup() {
        rm -f ${host_csr} ${host_new_cert} ${host_vdsmkey} /tmp/openssl.cnf
}

echo -n "Renew vdsm certificate on ${host_to_renew}..."
host_subject=$(ssh -i /etc/pki/ovirt-engine/keys/engine_id_rsa root@${host_to_renew} "openssl x509 -in /etc/pki/vdsm/certs/vdsmcert.pem -noout -subject |sed -e 's/subject=/\//;s/ //g;s/,/\//'")
host_vds_unique_id=$(ssh -i /etc/pki/ovirt-engine/keys/engine_id_rsa root@${host_to_renew} "vdsm-tool vdsm-id")
host_vds_id=$(su - postgres -c "psql engine --csv -c \"select vds_id from vds_static where vds_unique_id='${host_vds_unique_id}'\" |tail -1")
host_vds_host_name=$(su - postgres -c "psql engine --csv -c \"select host_name from vds_static where vds_id='${host_vds_id}'\" |tail -1")
ip_regexp='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
if [ "${host_subject/${host_vds_host_name}/}" == ${host_subject} ] || [[ ${host_vds_host_name} =~ ${ip_regexp} ]]; then
        san_type=DNS
        if [[ ${host_vds_host_name} =~ ${ip_regexp} ]]; then
                san_type=IP
        fi
        altname=x
fi
scp -q -i /etc/pki/ovirt-engine/keys/engine_id_rsa ${host_to_renew}:/etc/pki/vdsm/keys/vdsmkey.pem ${host_vdsmkey} || { echo FAILED; echo "ERROR: Could not fetch vdsmkey.pem"; cleanup; exit 255; }
cd /etc/pki/ovirt-engine/
openssl req -new -key ${host_vdsmkey} -out ${host_csr} -passin "pass:mypass" -passout "pass:mypass" -batch -subj "/" || { echo FAILED; echo "ERROR: Failed to generate CSR"; cleanup; exit 255; }
if [ -n "${altname}" ]; then
        cp openssl.conf /tmp/openssl.conf
        echo -e "\n[SAN]\nsubjectAltName = ${san_type}:${host_vds_host_name}" >>/tmp/openssl.conf
        openssl ca -batch -policy policy_match -config /tmp/openssl.conf -extensions SAN -cert ca.pem -keyfile  private/ca.pem -days +398 -in ${host_csr} -out ${host_new_cert} -startdate "$(date --utc --date "now -1 days" +"%y%m%d%H%M%SZ")" -subj "${host_subject}" -utf8 >/dev/null 2>&1 || { echo FAILED; echo "ERROR: Failed to sign CSR"; cleanup; exit 255; }
else
        openssl ca -batch -policy policy_match -config openssl.conf -cert ca.pem -keyfile  private/ca.pem -days +398 -in ${host_csr} -out ${host_new_cert} -startdate "$(date --utc --date "now -1 days" +"%y%m%d%H%M%SZ")" -subj "${host_subject}" -utf8 >/dev/null 2>&1 || { echo FAILED; echo "ERROR: Failed to sign CSR"; cleanup;  exit 255; }
fi
echo DONE

echo -n "Copying new certificate to ${host_to_renew}..."
for cert_dst in "/etc/pki/vdsm/certs/vdsmcert.pem" "/etc/pki/vdsm/libvirt-spice/server-cert.pem" "/etc/pki/libvirt/clientcert.pem" "/etc/pki/vdsm/libvirt-vnc/server-cert.pem" "/etc/pki/vdsm/libvirt-migrate/server-cert.pem"
do
        scp -q -i /etc/pki/ovirt-engine/keys/engine_id_rsa ${host_new_cert} ${host_to_renew}:${cert_dst} || { echo FAILED; echo "ERROR: Failed to copy cert to ${cert_dst}"; cleanup; exit 255; }
done
ssh -i /etc/pki/ovirt-engine/keys/engine_id_rsa ${host_to_renew} "unalias cp; cp -p /etc/pki/vdsm/libvirt-vnc/server-key.pem /etc/pki/vdsm/libvirt-vnc/server-key.pem.bkp && cp -f -p /etc/pki/vdsm/keys/vdsmkey.pem /etc/pki/vdsm/libvirt-vnc/server-key.pem" || { echo FAILED; echo "ERROR: Failed to backup and copy libvirt-vnc/server-key.pem"; cleanup; exit 255; }
echo DONE

echo -n "Disable power management on ${host_to_renew}..."
su - postgres -c "psql -q engine -c \"update vds_static set pm_enabled=false where vds_id='${host_vds_id}'\"" || { echo FAILED; echo "ERROR: Failed to disable power management"; cleanup; exit 255; }
echo DONE

echo -n "Restart libvirt and vdsm on ${host_to_renew}..."
ssh -i /etc/pki/ovirt-engine/keys/engine_id_rsa root@${host_to_renew} "systemctl restart libvirtd vdsmd" || { echo FAILED; echo "ERROR: Failed to restart services"; cleanup; exit 255; }
echo DONE

echo -n "Wait for ${host_to_renew} to come up..."
sleep 10
TIMEOUT=300
while [ $(su - postgres -c "psql engine --csv -c \"select status from vds_dynamic where vds_id='${host_vds_id}'\" |tail -1") -ne 3 ]
do
        let TIMEOUT=$((TIMEOUT - 5))
        if [ ${TIMEOUT} -eq 0 ]; then
                echo FAILED
                echo "ERROR: Host did not come up after service restart"
                cleanup
                exit 255
        fi
        sleep 5
done
echo DONE

echo -n "Enable power management on ${host_to_renew}..."
su - postgres -c "psql -q engine -c \"update vds_static set pm_enabled=true  where vds_id='${host_vds_id}'\"" || { echo FAILED; echo "ERROR: Failed to enable power management"; cleanup; exit 255; }
echo DONE

cleanup

