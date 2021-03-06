#!/bin/bash
set -x

if [ $# -ne 1 ]; then
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
git clone --branch="build-$1" "https://github.com/Erebot/erebot.github.io.git" tmp/output || \
    ( mkdir -p tmp/output && git --git-dir=tmp/output/.git --work-tree=tmp/output init )

# Find the name of the default branch
DEFAULT_BRANCH="$(git --git-dir=tmp/clone/.git symbolic-ref --short refs/remotes/origin/HEAD | cut -d/ -f2-)"

# Find currently valid branches & tags, without the "refs/" prefix
VALID_REFS="$(git --git-dir=tmp/clone/.git show-ref --heads --tags | cut -c47- | sort -V)"

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
        echo ""
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
  # $4 = slug
  echo "Building $2 doc for $4 into $3"
  case "$2" in
    html)
      sphinx-build -T -E -b html -d ../_build/doctrees -D language="$1" . "$3/html" > "$3/../.logs/$2_$1.log" 2>&1 || \
      rm -vrf "$3/html/"
      ;;
    pdf)
      sphinx-build -T -E -b latex -d ../_build/doctrees -D language="$1" . "$3/pdf" > "$3/../.logs/$2_$1.log" 2>&1 && \
      make -C "$3/pdf/" all-pdf >> "$3/../.logs/$2_$1.log" 2>&1 < /dev/null
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

# Find documented references
DOCS=$( (find tmp/output -mindepth 2 -maxdepth 2 -type d -printf '%P\n' | grep -v '^\.git/') || true )

# Remove existing documentation that has no counterpart in the repository's
# current state or that is known to be obsolete
for outdir in $DOCS; do
    inref=$(get_input_ref "$outdir")
    ref1=$(git --git-dir tmp/clone/.git show-ref -s "refs/$inref")
    ref2=$(cat "tmp/output/$outdir/.commit")
    if [ "$ref1" != "$ref2" ]; then
        git --git-dir "tmp/output/.git" --work-tree "tmp/output" rm -rf "$outdir"
    fi
done

# Build the doc for each tag/branch
printf "{" > tmp/doc.json
docrefs=0
for ref in $VALID_REFS; do
    # Check the reference out
    git --git-dir "tmp/clone/.git" --work-tree "tmp/clone" checkout --force "$ref"

    # Copy or link the files required to build the documentation
    cp -avf ./*.py "tmp/clone/docs/src/"
    ln -vsfT ../../vendor tmp/clone/vendor

    # Find the languages available in that reference
    LANGS="$(find tmp/clone/docs/i18n/ -mindepth 1 -maxdepth 1 -type d -printf '%f\000' | sort -z | xargs -0 printf '%s ')"

    # Locate the output directory and prepare it
    outdir=$(get_output_dir "$ref")
    if [ -z "$outdir" ]; then
        continue
    fi
    mkdir -vp "tmp/output/$outdir/.logs"

    # For each language, build the doc in both HTML & PDF
    pushd "tmp/clone/docs/src/"
    for lang in $LANGS; do
        # Compile the translation catalogs for that language
        while IFS= read -r -d $'\0' po; do
            pybabel compile -f --statistics -i "$po" -o "${po%.po}.mo"
        done < <( find ../i18n/$lang/LC_MESSAGES/ -name '*.po' -print0 )

        mkdir -p "../../../output/$outdir/$lang"
        if [ ! -e "../../../output/$outdir/$lang/html" ]; then
            build "$lang" html  "../../../output/$outdir/$lang" "$1"
        fi
        if [ ! -e "../../../output/$outdir/$lang/pdf" ]; then
            build "$lang" pdf   "../../../output/$outdir/$lang" "$1"
        fi
        rm -vd "../../../output/$outdir/$lang" || true
    done
    popd

    # If at least one doc was successfully built,
    # add this reference to the JSON manifest.
    langcount=$(find "tmp/output/$outdir/" -mindepth 1 -maxdepth 1 -type d -a '!' -name .logs | wc -l)
    if [ $langcount -gt 0 ]; then
        if [ $docrefs -gt 0 ]; then
            printf "," >> tmp/doc.json
        fi

        # We know that at least one language has some documentation
        # for this reference. Add it to the manifest.
        printf '"%s":{' "${outdir#*/}" >> tmp/doc.json
        langindex=0
        for lang in $LANGS; do
            if [ ! -d "tmp/output/$outdir/$lang" ]; then
                continue
            fi

            if [ $langindex -gt 0 ]; then
                printf "," >> tmp/doc.json
            fi
            langindex=$((langindex + 1))

            # We know this language contains some documentation, trace that.
            printf '"%s":[' "$lang" >> tmp/doc.json

            # Find all available documentation formats for that language,
            # add quotes around every entry, then join them with commas
            # and store the result inside the manifest.
            find "tmp/output/$outdir/$lang" -mindepth 1 -maxdepth 1 -type d -printf "%P\0" | \
                sed -z -r 's/^(.+)$/"\1"/g;2,$s/^/,/' | xargs -0 printf "%s" >> tmp/doc.json

            printf "]" >> tmp/doc.json
        done
        printf "}" >> tmp/doc.json
        docrefs=$((docrefs + 1))
    fi

    # Save the commit's hash for future reference
    git --git-dir "tmp/clone/.git" show-ref -s "refs/$ref" > "tmp/output/$outdir/.commit"
done
echo "}" >> tmp/doc.json

# For debugging purposes
cat tmp/doc.json

# Add the manifest to the overlay
printf ";" | cat tmp/doc.json /dev/stdin | tr -d '\n' | \
sed 's/^/  var metadata = /' | sed '/@METADATA@/{
r /dev/stdin
d
}' erebot-overlay.js > "tmp/output/erebot-overlay.js"


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

rm -rf tmp/output/.git
touch .deploy
