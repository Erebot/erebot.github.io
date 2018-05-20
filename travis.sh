#!/bin/bash

function die()
{
    echo "Error during this call:"
    caller 0
    exit 1
}
trap die ERR

# Do not attempt to build pull requests
if [ -n "$ORIG_TRAVIS_PULL_REQUEST_SLUG" ] || [ -n "$TRAVIS_PULL_REQUEST_SLUG" ]; then
    exit 1
fi

# Build only for tags, or commits to "master" or "develop"
if [ -z "$ORIG_TRAVIS_TAG" ] && [ "$ORIG_TRAVIS_BRANCH" != "master" ] && [ "$ORIG_TRAVIS_BRANCH" != "develop" ]; then
    exit 1
fi

# Prepare the environment
mkdir -p "tmp/output" "tmp/clone"
git clone --branch="$ORIG_TRAVIS_BRANCH" "https://github.com/${ORIG_TRAVIS_REPO_SLUG}.git" "tmp/clone"
git --git-dir="tmp/clone/.git" checkout "$ORIG_TRAVIS_COMMIT"
cp -avf *.py "tmp/clone/docs/src/"
mv vendor "tmp/clone/"

DEFAULT_BRANCH=`git --git-dir="tmp/clone/.git" symbolic-ref --short refs/remotes/origin/HEAD | cut -d/ -f2-`
DOC_LANGUAGES=`printf "%s " $(ls -1 "tmp/clone/docs/i18n/")`

# Determine the name of the output directory
if [ -n "$ORIG_TRAVIS_TAG" ]; then
    export OUTDIR="tag/$ORIG_TRAVIS_TAG"
elif [ "$ORIG_TRAVIS_BRANCH" = "$DEFAULT_BRANCH" ]; then
    export OUTDIR="alias/latest"
elif [ "$ORIG_TRAVIS_BRANCH" = "master" ]; then
    export OUTDIR="alias/stable"
else
    exit 1
fi

# Clone the repository again inside a special temporary folder,
# and clean things up a little
git clone --branch=master https://github.com/Erebot/erebot.github.io.git "tmp/output"
rm -rf "tmp/output/.git"
rm -rf "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}"
mkdir -p "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/alias" "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/tag"

# Build the new documentation
pushd "tmp/clone/docs/src/"
for lang in $DOC_LANGUAGES; do
    sphinx-build -T -E -b html -d ../_build/doctrees -D language="$lang" . "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$lang/html"
    sphinx-build -T -E -b latex -d ../_build/doctrees -D language="$lang" . "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$lang/pdf"
    make -C "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$lang/pdf/" all-pdf < /dev/null || /bin/true
    find "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$lang/pdf/" ! -name "*.pdf"
done
popd

# Add a redirection if necessary
if [ ! -f "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/index.html" ]; then
  cat > "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/index.html" <<EOF
<!DOCTYPE html>
<html>
  <head>
    <meta http-equiv="refresh" content="0; url=alias/latest/en/html/"/>
  </head>
  <body onload="window.location.replace('alias/latest/en/html/');"></body>
</html>
EOF
fi

# Update the overlay with available languages/versions
DOC_VERSIONS="$(cd "tmp/clone/${ORIG_TRAVIS_REPO_SLUG}"; find alias/ tag/ -mindepth 1 -maxdepth 1 '(' -type d -o -type l ')' -printf '%f ' 2> /dev/null)"
printf "Languages\n---------\n%s\n\nVersions\n--------\n%s\n" "${DOC_LANGUAGES}" "${DOC_VERSIONS}"
sed -e "s^//languages//^languages = '${DOC_LANGUAGES}'^"                                \
    -e "s^//versions//^versions = '${DOC_VERSIONS}'^" "tmp/output/erebot-overlay.js"    \
    > "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/erebot-overlay.js"
