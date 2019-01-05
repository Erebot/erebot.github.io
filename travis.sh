#!/bin/bash
set -v

if [ -z "$1" ]; then
    echo "Usage: ./travis.sh <slug>" >&2
    exit 1
fi

function die()
{
    echo "Error during this call:" >&2
    caller 0 >&2
    exit 42
}
trap die ERR

# Do not attempt to build pull requests
if [ "$TRAVIS_PULL_REQUEST" != "false" ]; then
    exit 1
fi

# Prepare the environment
mkdir -p "tmp/output" "tmp/clone"

# Clone the module and current doc for that module
git clone "https://github.com/$1.git" "tmp/clone"
git clone --branch="build-$1" "https://github.com/Erebot/erebot.github.io.git" "tmp/output" || git --git-dir=tmp/output/.git --work-tree=tmp/output init

# Copy the files required to build the doc to the module's clone
cp -avf ./*.py "tmp/clone/docs/src/"
mv -v vendor "tmp/clone/"

# Find the name of the default branch
DEFAULT_BRANCH="$(git --git-dir=tmp/clone/.git symbolic-ref --short refs/remotes/origin/HEAD | cut -d/ -f2-)"

# Find currently valid branches & tags
VALID_REFS="$(find tmp/clone/.git/refs -type f -printf '%P\n' | grep -P '^(tags/.*|heads/(master|develop))$')"

# Determine the name of the output directory given a reference
# $1 = reference name
function get_output_dir()
{
    if [[ "$1" =~ ^tags/ ]]; then
        echo "tag/${1#*/}" # Replace "tags/1.2.3" with "tag/1.2.3"
    elif [ "$1" = "heads/$DEFAULT_BRANCH" ]; then
        echo "alias/latest"
    elif [ "$1" = "heads/master" ]; then
        echo "alias/stable"
    else
        exit 1
    fi
}

# Determine the original reference given the name of an output directory
# $1 = short name for the directory (eg. "alias/latest")
function get_input_ref()
{
    if [[ "$1" =~ ^tag/ ]]; then
        echo "tags/${1#*/}" # Replace "tag/1.2.3" with "tags/1.2.3"
    elif [ "$1" = "alias/latest" ]; then
        echo "heads/$DEFAULT_BRANCH"
    elif [ "$1" = "alias/stable" ]; then
        echo "heads/master"
    else
        exit 1
    fi
}

# This is the function that does the actual workload
# of building a module's documentation
function build()
{
  # $1 = language
  # $2 = format
  # $3 = output directory
  case "$2" in
    html)
      sphinx-build -T -E -b html -d ../_build/doctrees -D language="$1" . "$3/html" || \
      rm -vrf "$3/html/"
      ;;
    pdf)
      sphinx-build -T -E -b latex -d ../_build/doctrees -D language="$1" . "$3/pdf" && \
      make -C "$3/pdf/" all-pdf < /dev/null
      if [ $? -eq 0 ]; then
        find "$3/pdf/" ! -name "*.pdf"
      else
        rm -vrf "$3/pdf/"
      fi
      ;;
    *)
      echo "Unsupported format: $2" >&2
      exit 1
      ;;
  esac
}


# Remove existing documentation that has no counterpart in the repository's
# current state or that is obsolete.
DOCS=$(find tmp/output -mindepth 2 -maxdepth 2 -type d)
for outdir in $DOCS; do
    inref=$(get_input_ref "$outdir")
    ref1=$(git --git-dir tmp/clone/.git show-ref -s "refs/$inref")
    ref2=$(cat "tmp/output/$outdir/.commit")
    if [ "$ref1" != "$ref2" ]; then
        git --git-dir "tmp/output/.git" --work-tree "tmp/output" rm -rf "$outdir"
    fi
done

# For each tag/branch,
for ref in $VALID_REFS; do
    # Check the reference out
    git --git-dir "tmp/clone/.git" --work-tree "tmp/clone" checkout --force "$ref"

    # Find the languages available in that reference
    LANGS="$(find tmp/clone/docs/i18n/ -mindepth 1 -maxdepth 1 -type d -printf '%f\000' | sort -z | xargs -0 printf '%s ')"

    outdir=$(get_output_dir "$ref")
    pushd "tmp/clone/docs/src/"

    # For each language, build the doc in both HTML & PDF
    mkdir -vp "../../../output/$outdir"
    for lang in $LANGS; do
        mkdir "../../../output/$outdir/$lang"
        build "$lang" html  "../../../output/$outdir/$lang"
        build "$lang" pdf   "../../../output/$outdir/$lang"
        rm -vd "../../../output/$outdir/$lang" || /bin/true
    done
    rm -vd "../../../output/$outdir" || /bin/true

    # Sanity check
    if [ ! -d "tmp/output/$outdir" ]; then
      echo "Fatal error: no output produced" >&2
      exit 1
    fi
    popd
done



## Add a redirection if necessary
#if [ -d "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/${OUTDIR}/alias/latest/en/html" ] && \
#   [ ! -f "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/index.html" ]; then
#  cat > "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/index.html" <<EOF
#<!DOCTYPE html>
#<html>
#  <head>
#    <meta http-equiv="refresh" content="0; url=alias/latest/en/html/"/>
#  </head>
#  <body onload="window.location.replace('alias/latest/en/html/');"></body>
#</html>
#EOF
#fi

## Update the overlay with available languages/versions
#pushd "tmp/output/${ORIG_TRAVIS_REPO_SLUG}"
#DOC_VERSIONS="$(find alias/ tag/ -mindepth 1 -maxdepth 1 '(' -type d -o -type l ')' -printf '%f ' 2> /dev/null | sort -Vr)"
#DOC_LANGUAGES="$(find alias/ tag/ -mindepth 2 -maxdepth 2 '(' -type d -o -type l ')' -printf '%f\n' 2> /dev/null | sort | uniq | xargs printf '%s ')"
#DOC_FORMATS="$(find alias/ tag/ -mindepth 3 -maxdepth 3 '(' -type d -o -type l ')' -printf '%f\n' 2> /dev/null | sort | uniq | xargs printf '%s ')"
#popd

#printf "\nLanguages\n---------\n%s\n\nVersions\n--------\n%s\nFormats\n-------" "${DOC_LANGUAGES}" "${DOC_VERSIONS}" "${DOC_FORMATS}"
#sed -e "s^//languages//^languages = '${DOC_LANGUAGES}'^"  \
#    -e "s^//versions//^versions = '${DOC_VERSIONS}'^"     \
#    -e "s^//formats//^formats = '${DOC_FORMATS}'^"        \
#    "erebot-overlay.js" > "tmp/output/${ORIG_TRAVIS_REPO_SLUG}/erebot-overlay.js"

touch .deploy
