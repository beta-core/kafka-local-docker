#!/bin/bash

function make_folders {
    #
    # Makes the directories if they don't exisit
    #
    mkdir -p ca
    mkdir -p client
    mkdir -p cnf
    mkdir -p jks
}

function check_key_file {
    PASS_KEY_FILE=jks/kafka.key
    if [ ! -f $PASS_KEY_FILE ]; then
        echo "Key store password not found time to set it"
        read PW
        echo $PW >> $PASS_KEY_FILE
    fi
    # This is for testing please don't use in production
    TRUST_STORE_PASS=$(<$PASS_KEY_FILE)
    CA_ROOT_PASS=$(<$PASS_KEY_FILE)
    KEY_STORE_PASS=$(<$PASS_KEY_FILE)
}

function set_variables {
    ROOT_AUTH=ca/ca.crt
    ROOT_AUTH_KEY=ca/ca.key
    ROOT_ALIAS=CARoot
    TRUST_STORE_FILE=jks/kafka.server.truststore.jks
}


function create_ca {
    echo "Creating CA"
    openssl req \
        -new \
        -x509 \
        -keyout $ROOT_AUTH_KEY \
        -out $ROOT_AUTH \
        -days 365 \
        -passout pass:$CA_ROOT_PASS
    openssl rsa -check -in $ROOT_AUTH_KEY -passin pass:$CA_ROOT_PASS
    openssl x509 -text -noout -in $ROOT_AUTH
}


function trust_store {
    rm -f $TRUST_STORE_FILE
    keytool -storepass $KEY_STORE_PASS \
        -keystore $TRUST_STORE_FILE \
        -trustcacerts \
        -alias $ROOT_ALIAS \
        -import \
        -file $ROOT_AUTH \
        -noprompt
    declare -a client_certs=("$(ls -d client | grep "\.crt$")")
    for cert in client/*.crt; do
        echo "Cert name $cert"
        alias="$(echo $cert | sed -En "s/client\/(.*)(\.crt)/\1/p")"
        echo "Cert alias $alias"
        keytool -storepass $KEY_STORE_PASS \
            -srckeystore $TRUST_STORE_FILE \
            -destkeystore $TRUST_STORE_FILE \
            -trustcacerts \
            -import \
            -alias $alias \
            -file $cert \
            -noprompt
    done
    keytool -list -v -keystore $TRUST_STORE_FILE -storepass $KEY_STORE_PASS
}

function sign_cert {
    CERT_FILE=$1
    VALIDITY=30
    CERT_ALIAS=$1

    echo "Creating cnf"
    cat template.cnf | sed "s/%%name%%/${CERT_FILE}/g" > cnf/$CERT_FILE.cnf
    CONFIG_FILE=cnf/$1.cnf

    echo "Ganerating Key"
    openssl genrsa -aes128 -passout pass:${KEY_STORE_PASS} -out client/$CERT_FILE.key 3072
    openssl rsa -check -in client/$CERT_FILE.key -passin pass:${KEY_STORE_PASS}

    echo "Create Cert Request"
    openssl req \
            -new \
            -newkey rsa:4096 \
            -nodes \
            -config $CONFIG_FILE \
            -outform pem \
            -passin pass:$KEY_STORE_PASS \
            -key client/$CERT_FILE.key \
            -out client/$CERT_FILE.csr

    echo "Sign cert Request with ca"
    openssl x509 -req \
                -CA $ROOT_AUTH \
                -CAkey $ROOT_AUTH_KEY \
                -passin pass:$CA_ROOT_PASS \
                -in client/$CERT_FILE.csr \
                -out client/$CERT_FILE.crt \
                -days $VALIDITY \
                -CAcreateserial


    openssl x509 -in client/$CERT_FILE.crt -text -noout
    echo "Generating pkcs12"


    openssl pkcs12 -export \
            -in client/$CERT_FILE.crt\
            -inkey client/$CERT_FILE.key \
            -passin pass:$CA_ROOT_PASS \
            -chain\
            -CAfile $ROOT_AUTH \
            -name $CERT_FILE \
            -out client/$CERT_FILE.p12 \
            -passout pass:$CA_ROOT_PASS
}
function key_store {

    CERT_FILE=$1
    KEY_STORE_FILE=jks/$CERT_FILE.keystore.jks
    echo "Adding Key to Java key store"
    echo "Import into ${KEY_STORE_FILE}:"
    rm -f $KEY_STORE_FILE
    keytool -importkeystore \
        -srckeystore client/$CERT_FILE.p12 \
        -srcstorepass $KEY_STORE_PASS \
        -srcstoretype PKCS12 \
        -destkeystore $KEY_STORE_FILE \
        -deststorepass $KEY_STORE_PASS \
        -deststoretype pkcs12
    keytool -list -v -keystore $KEY_STORE_FILE -storepass $KEY_STORE_PASS
}

function main {
    make_folders
    check_key_file
    set_variables
}
main
