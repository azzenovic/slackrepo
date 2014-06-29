#!/bin/bash
# Copyright 2014 David Spencer, Baildon, West Yorkshire, U.K.
#   All rights reserved.  For licence details, see the file 'LICENCE'.
#
# Contains code and concepts from 'gen_repos_files.sh' 1.90
#   Copyright (c) 2006-2013  Eric Hameleers, Eindhoven, The Netherlands
#   All rights reserved.  For licence details, see the file 'LICENCE'.
#   http://www.slackware.com/~alien/tools/gen_repos_files.sh
#
#-------------------------------------------------------------------------------
# revfunctions.sh - revision control functions for slackrepo
#   print_current_revinfo
#   needs_build
#-------------------------------------------------------------------------------

declare -A REVCACHE

function print_current_revinfo
# Prints a revision info summary on standard output, format as follows:
#
# Each line contains the following assignments, space-separated:
#   prgnam=<prgnam>;
#   version=<version>;
#   built=<secs-since-epoch>;
#   buildrev=<gitrevision|secs-since-epoch>;
#   slackware=<slackversion>;
#   [depends=<dep1>[:<dep2>[...]];]
#   [hintfile=<md5sum>;]
#
# This is repeated for each dependency.
#
# $1 = itemid
# Return status always 0
{
  [ "$OPT_TRACE" = 'y' ] && echo -e ">>>> ${FUNCNAME[@]}\n     $*" >&2

  local itemid="$1"
  local itemprgnam=${ITEMPRGNAM[$itemid]}
  local itemdir=${ITEMDIR[$itemid]}

  prgstuff="prgnam=${itemprgnam};"

  verstuff="version=${HINT_VERSION[$itemid]:-${INFOVERSION[$itemid]}};"

  bltstuff="built=$(date +%s);"

  if [ "$GOTGIT" = 'y' ]; then
    rev="${GITREV[$itemid]}"
    [ "${GITDIRTY[$itemid]}" = 'y' ] && rev="${rev}+dirty"
  else
    # Use newest file's seconds since epoch ;-)
    rev="$(cd $SR_SBREPO/$itemdir; ls -t | head -n 1 | xargs stat --format='%Y')"
  fi
  revstuff="buildrev=${rev};"

  slackstuff="slackware=${SYS_SLACKVER};"

  depstuff=''
  directdeps=$(echo "${DIRECTDEPS[$itemid]}" | sed 's/ /:/g')
  [ -n "$directdeps" ] && depstuff="depends=${directdeps};"

  hintstuff=''
  if [ -n "${HINTFILE[$itemdir]}" ]; then
    hintstuff="hintfile=$(md5sum "${HINTFILE[$itemdir]}" | sed 's/ .*//');"
  fi

  REVCACHE[$itemid]=$(echo ${prgstuff} ${verstuff} ${bltstuff} ${revstuff} ${slackstuff} ${depstuff} ${hintstuff})
  echo ${REVCACHE[$itemid]}

  for dep in ${DIRECTDEPS[$itemid]}; do
    if [ -n "${REVCACHE[$dep]}" ]; then
      deprev="${REVCACHE[$dep]}"
    elif [ "$OPT_DRY_RUN" = 'y' -a -f $DRYREPO/$dep/.revision ]; then
      deprev=$(head -q -n 1 $DRYREPO/$dep/.revision)
      REVCACHE[$dep]="$deprev"
    else
      deprev=$(head -q -n 1 $SR_PKGREPO/$dep/.revision)
      REVCACHE[$dep]="$deprev"
    fi
    echo "$deprev"
  done

  return 0
}

#-------------------------------------------------------------------------------

function needs_build
# Works out whether the package needs to be built.
# $1 = itemid
# Return status:
# 0 = yes, needs to be built
# 1 = no, does not need to be built
# Also sets these variables when status=0:
# BUILDINFO = friendly changelog-style message describing the build
{
  [ "$OPT_TRACE" = 'y' ] && echo -e ">>>> ${FUNCNAME[@]}\n     $*" >&2

  local itemid="$1"
  local itemprgnam=${ITEMPRGNAM[$itemid]}
  local itemdir=${ITEMDIR[$itemid]}
  local -a pkglist modifilelist
  local prgnam version built revision depends slackware hintfile

  if [ "$OPT_DRY_RUN" = 'y' ]; then
    pkglist=( $(ls "$DRYREPO"/"$itemdir"/*.t?z 2>/dev/null) )
    [ "${#pkglist[@]}" = 0 ] && \
      pkglist=( $(ls "$SR_PKGREPO"/"$itemdir"/*.t?z 2>/dev/null) )
  else
    pkglist=( $(ls "$SR_PKGREPO"/"$itemdir"/*.t?z 2>/dev/null) )
  fi

  # Package dir not found or has no packages => add
  if [ "${#pkglist[@]}" = 0 ]; then
    BUILDINFO="add version ${HINT_VERSION[$itemid]:-${INFOVERSION[$itemid]}}"
    return 0
  fi

  # Is the .revision file missing => add
  PKGREVFILE=$(dirname "${pkglist[0]}")/.revision
  if [ ! -f "$PKGREVFILE" ]; then
    BUILDINFO="add version ${HINT_VERSION[$itemid]:-${INFOVERSION[$itemid]}}"
    return 0
  fi

  eval $(head -q -n 1 "$PKGREVFILE")
  pkgver="$version"
  pkgblt="$built"
  pkgrev="$buildrev"
  pkgdep="$depends"
  pkgslk="$slackware"
  pkghnt="$hintfile"

  # Are we upversioning => update
  currver="${HINT_VERSION[$itemid]:-${INFOVERSION[$itemid]}}"
  if [ "$pkgver" != "$currver" ]; then
    BUILDINFO="update for version $currver"
    return 0
  fi

  modifilelist=( $(find -L "$SR_SBREPO"/"$itemdir" -newermt @"$pkgblt" 2>/dev/null) )

  # If this isn't a git repo, and any of the files have been modified since the package was built => update
  if [ "$GOTGIT" = 'n' -a ${#modifilelist[@]} != 0 ]; then
    BUILDINFO="update for modified files"
    return 0
  fi

  dirtymark=''
  [ "${GITDIRTY[$itemid]}" = 'y' ] && dirtymark='+dirty'
  currrev="${GITREV[$itemid]}$dirtymark"
  shortcurrrev="${currrev:0:7}$dirtymark"

  # Has the build revision (e.g. SlackBuild git rev) changed => update
  if [ "$pkgrev" != "$currrev" ]; then
    BUILDINFO="update for git $shortcurrrev"
    return 0
  fi

  # If git is dirty, and any of the files have been modified since the package was built => update
  if [ "${GITDIRTY[$itemid]}" = 'y' -a ${#modifilelist[@]} != 0 ]; then
    BUILDINFO="update for git $shortcurrrev"
    return 0
  fi

  # Is this the top-level item and are we in rebuild mode
  #   => rebuild if it hasn't previously been rebuilt (as a dep of something else)
  if [ "$itemid" = "$ITEMID" -a "$PROCMODE" = 'rebuild' ]; then
    found='n'
    for previously in "${OKLIST[@]}"; do
      if [ "$previously" = "$ITEMID" ]; then found='y'; break; fi
    done
    if [ "$found" = 'n' ]; then
      BUILDINFO="rebuild"
      return 0
    fi
  fi

  # Has the list of deps changed => rebuild
  currdep=$(echo "${DIRECTDEPS[$itemid]}" | sed 's/ /:/g')
  if [ "$pkgdep" != "$currdep" ]; then
    BUILDINFO="rebuild for added/removed deps"
    return 0
  fi

  # Have any of the deps been updated => rebuild
  local -a updeps
  for dep in ${DIRECTDEPS[$itemid]}; do
    # ignore built= (merely rebuilt deps don't matter) and hintfile= (significant
    # hintfile changes will affect version= or depends=, which *are* checked)
    pkgdeprev=$(grep "^prgnam=${ITEMPRGNAM[$dep]};" $PKGREVFILE | sed -e 's/ built=[0-9]*;//' -e 's/ hintfile=[0-9a-f]*;//' )
    if [ -z "${REVCACHE[$dep]}" ]; then
      # if there is nothing in REVCACHE, the dep's package can't be in DRYREPO
      REVCACHE[$dep]="$(head -q -n 1 "$SR_PKGREPO"/"${ITEMDIR[$dep]}"/.revision)"
    fi
    currdeprev="$(echo ${REVCACHE[$dep]} | sed -e 's/ built=[0-9]*;//' -e 's/ hintfile=[0-9a-f]*;//')"
    [ "$pkgdeprev" != "$currdeprev" ] && updeps+=( "$dep" )
  done
  if [ "${#updeps}" != 0 ]; then
    log_verbose "Updated dependencies of ${itemid}:"
    log_verbose "$(printf '  %s\n' "${updeps[@]}")"
    BUILDINFO="rebuild for updated deps"
    return 0
  fi

  # Has Slackware changed => rebuild
  currslk="$SYS_SLACKVER"
  if [ "$pkgslk" != "$currslk" ]; then
    BUILDINFO="rebuild for upgraded Slackware"
    return 0
  fi

  # Has the hintfile changed => rebuild
  currhnt=''
  if [ -n "${HINTFILE[$itemdir]}" ]; then
    currhnt="$(md5sum "${HINTFILE[$itemdir]}" | sed 's/ .*//')"
  fi
  if [ "$pkghnt" != "$currhnt" ]; then
    BUILDINFO="rebuild for hintfile changes"
    return 0
  fi

  # ok, it is genuinely up to date!
  if [ "$itemid" = "$ITEMID" ]; then
    log_important "$itemid is up-to-date."
  else
    log_normal "$itemid is up-to-date."
  fi
  return 1

}
