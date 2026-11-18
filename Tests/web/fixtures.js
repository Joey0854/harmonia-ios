// Made-up YouTube Music answers in the shapes the backend reads (no real account, song or token).
'use strict';

// an 11-character videoId from a short name: "s01" -> "s01________"
const vid = (name) => (name + '___________').slice(0, 11);
const runs = (text) => ({ runs: [{ text }] });

// one song in a radio ("next" endpoint)
function panelSong(name, artist) {
  return {
    playlistPanelVideoRenderer: {
      videoId: vid(name), title: runs('Song ' + name), shortBylineText: runs(artist || 'Artist ' + name),
      lengthText: runs('3:30'), thumbnail: { thumbnails: [{ url: 'https://example.invalid/t.jpg', width: 226, height: 226 }] },
    },
  };
}
const radioToken = (t) => ({ nextRadioContinuationData: { continuation: t } });

// the first answer of a radio: the queue panel with the token for the rest
function nextFirst(names, token) {
  return {
    contents: { singleColumnMusicWatchNextResultsRenderer: { tabbedRenderer: { watchNextTabbedResultsRenderer: { tabs: [{
      tabRenderer: { content: { musicQueueRenderer: { content: { playlistPanelRenderer: {
        contents: names.map((n) => panelSong(n)), continuations: token ? [radioToken(token)] : [],
      } } } } },
    }] } } } },
  };
}
// the answer to a radio's continuation
function nextMore(names, token) {
  return { continuationContents: { playlistPanelContinuation: { contents: names.map((n) => panelSong(n)), continuations: token ? [radioToken(token)] : [] } } };
}

// one song in a list (playlist, liked songs)
function listSong(name) {
  return {
    musicResponsiveListItemRenderer: {
      playlistItemData: { videoId: vid(name) },
      flexColumns: [
        { musicResponsiveListItemFlexColumnRenderer: { text: runs('Song ' + name) } },
        { musicResponsiveListItemFlexColumnRenderer: { text: runs('Artist ' + name) } },
      ],
      fixedColumns: [{ musicResponsiveListItemFixedColumnRenderer: { text: runs('3:30') } }],
    },
  };
}
const listToken = (t) => ({ continuationItemRenderer: { continuationEndpoint: { continuationCommand: { token: t } } } });

// the first page of a playlist: the list's own token at the end of the shelf, and a token of the
// page itself (more shelves below the list) that is not the list's
function browseFirst(names, token, pageToken) {
  return {
    header: { musicResponsiveHeaderRenderer: { title: runs('My list'), subtitle: runs('Playlist') } },
    contents: { twoColumnBrowseResultsRenderer: { secondaryContents: { sectionListRenderer: {
      contents: [{ musicPlaylistShelfRenderer: { contents: names.map(listSong).concat(token ? [listToken(token)] : []) } }],
      continuations: pageToken ? [{ nextContinuationData: { continuation: pageToken } }] : [],
    } } } },
  };
}
// a further page, as YouTube Music sends it now
function browseMore(names, token) {
  return { onResponseReceivedActions: [{ appendContinuationItemsAction: { continuationItems: names.map(listSong).concat(token ? [listToken(token)] : []) } }] };
}
// a further page in the older form
function browseMoreOld(names, token) {
  return { continuationContents: { musicPlaylistShelfContinuation: {
    contents: names.map(listSong), continuations: token ? [{ nextContinuationData: { continuation: token } }] : [],
  } } };
}

// a song item as the backend hands it to the page
function item(name, extra) {
  return Object.assign({ kind: 'song', title: 'Song ' + name, subtitle: 'Artist ' + name, thumb: '', videoId: vid(name), playlistId: '', browseId: '', duration: '3:30' }, extra || {});
}

module.exports = { vid, nextFirst, nextMore, browseFirst, browseMore, browseMoreOld, item };
