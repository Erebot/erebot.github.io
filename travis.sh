#!/bin/bash
set -v

function die()
{
    echo "Error during this call:" >&2
    caller 0 >&2
    exit 42
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
DOC_LANGUAGES=`printf "%s " $(ls -1 "tmp/clone/docs/i18n/" | sort)`

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

# Helper functions
function build()
{
  # $1 = language
  # $2 = format
  local res
  case "$2" in
    html)
      sphinx-build -T -E -b html -d ../_build/doctrees -D language="$1" . "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$1/html" || \
      rm -vrf "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$1/html/"
      ;;
    pdf)
      sphinx-build -T -E -b latex -d ../_build/doctrees -D language="$1" . "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$1/pdf" && \
      make -C "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$1/pdf/" all-pdf < /dev/null
      if [ $? -eq 0 ]; then
        find "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$1/pdf/" ! -name "*.pdf"
      else
        rm -vrf "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$1/pdf/"
      fi
      ;;
    *)
      echo "Unsupported format: $2" >&2
      exit 1
      ;;
  esac
}

# Build the new documentation
pushd "tmp/clone/docs/src/"
for lang in $DOC_LANGUAGES; do
  build "$lang" html
  build "$lang" pdf
  rm -d "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/$lang" || /bin/true
done
rm -d "../../../output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}" || /bin/true
popd

# Sanity check
if [ ! -d "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}" ]; then
  echo "Fatal error: no output produced" >&2
  exit 1
fi

# Add a redirection if necessary
if [ -d "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/alias/latest/en/html" ] && \
   [ ! -f "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/index.html" ]; then
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
pushd "tmp/output/${ORIG_TRAVIS_REPO_SLUG}"
DOC_VERSIONS=`find alias/ tag/ -mindepth 1 -maxdepth 1 '(' -type d -o -type l ')' -printf '%f ' 2> /dev/null | sort -Vr`
DOC_LANGUAGES=`find alias/ tag/ -mindepth 2 -maxdepth 2 '(' -type d -o -type l ')' -printf '%f\n' 2> /dev/null | sort | uniq | xargs printf '%s '`
DOC_FORMATS=`find alias/ tag/ -mindepth 3 -maxdepth 3 '(' -type d -o -type l ')' -printf '%f\n' 2> /dev/null | sort | uniq | xargs printf '%s '`
popd

printf "\nLanguages\n---------\n%s\n\nVersions\n--------\n%s\nFormats\n-------" "${DOC_LANGUAGES}" "${DOC_VERSIONS}" "${DOC_FORMATS}"
sed -e "s^//languages//^languages = '${DOC_LANGUAGES}'^"  \
    -e "s^//versions//^versions = '${DOC_VERSIONS}'^"     \
    -e "s^//formats//^formats = '${DOC_FORMATS}'^"        \
    "erebot-overlay.js" > "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/erebot-overlay.js"

echo 1 > .deploy
