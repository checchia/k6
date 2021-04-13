#!/bin/bash
set -eEuo pipefail

log() {
  echo "$(date -Iseconds) $*"
}

signkeypath="$PWD/sign-key.gpg"
s3bucket="${S3_BUCKET-dl.k6.io}"
pkgdir="$PWD/Packages"

if ! [ -r "$signkeypath" ]; then
  log "ERROR: Signing key not found at '$signkeypath'"
  exit 1
fi

gpg2 --import --batch --passphrase="$PGP_SIGN_KEY_PASSPHRASE" "$signkeypath"
export PGPKEYID="$(gpg2 --list-secret-keys --with-colons | grep '^sec' | cut -d: -f5)"
# Export and sync the GPG pub key if it doesn't exist in S3 already.
mkdir -p "$pkgdir"
aws s3 cp --no-progress "s3://${s3bucket}/key.gpg" "${pkgdir}/key.gpg" || {
  gpg2 --export --armor --output "${pkgdir}/key.gpg" "$PGPKEYID"
  aws s3 cp --no-progress "${pkgdir}/key.gpg" "s3://${s3bucket}/key.gpg"
}

# Setup RPM signing
cat > "$HOME/.rpmmacros" <<EOF
%_gpgbin        $(which gpg2)
%_gpg_path      $HOME/.gnupg
%_gpg_name      k6
%_gpg_pass      -
%__gpg_sign_cmd   %{__gpg} gpg2 --default-key="$PGPKEYID" --no-verbose --no-armor --pinentry-mode=loopback --yes --passphrase="$PGP_SIGN_KEY_PASSPHRASE" --no-secmem-warning --detach-sign -o %{__signature_filename} %{__plaintext_filename}
EOF

for repo in deb rpm msi; do
  log "Creating ${repo} repository ..."
  "create-${repo}-repo.sh" "$PWD/dist" "${pkgdir}/${repo}"
done

# Generate and sync the main index.html
(cd "$pkgdir" && generate_index.py)
aws s3 cp --no-progress --cache-control='max-age=60,must-revalidate' \
  "${pkgdir}/index.html" "s3://${s3bucket}/index.html"

# Invalidate CloudFront cache for index files, repo metadata and the latest MSI
# package redirect.
# TODO: Maybe just invalidate the entire bucket (/*), since CF charges per
# invalidation path.
IFS=' ' read -ra indexes <<< \
  "$(find "${pkgdir}" -name 'index.html' -type f | sed "s:^${pkgdir}::" | sort | paste -sd' ')"
aws cloudfront create-invalidation --distribution-id "$AWS_CF_DISTRIBUTION" \
  --paths "${indexes[@]}" "/msi/k6-latest-amd64.msi" \
  "/deb/dists/stable/"{Release,Release.gpg,InRelease} \
  "/deb/dists/stable/main/binary-amd64"/Packages{,.gz,.bz2} \
  "/rpm/x86_64/repodata/*"

exec "$@"
