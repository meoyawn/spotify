// Original PlaylistAPI decoration policies: reverse-engineering/fixtures/entity-oracle.json.
const playlistPolicyJson = r'''
{
  "base": {
    "playlist": {
      "link": true,
      "name": true,
      "loaded": true,
      "totalLength": true,
      "duration": true,
      "description": true,
      "picture": true,
      "playable": true,
      "canReportAnnotationAbuse": true,
      "followed": true,
      "followers": true,
      "ownedBySelf": true,
      "published": true,
      "formatListType": true,
      "formatListAttributes": true,
      "containsSpotifyTracks": true,
      "containsTracks": true,
      "containsEpisodes": true,
      "owner": {
        "username": true,
        "link": true,
        "name": true,
        "image": true,
        "thumbnail": true,
        "color": true
      },
      "madeFor": {
        "username": true,
        "link": true,
        "name": true,
        "image": true,
        "thumbnail": true,
        "color": true
      },
      "allows": {
        "insert": true,
        "remove": true
      },
      "numberOfEpisodes": true,
      "numberOfTracks": true,
      "collaboratingUsers": {
        "count": true,
        "limit": 5,
        "collaborator": {
          "user": {
            "username": true,
            "link": true,
            "name": true,
            "image": true,
            "thumbnail": true,
            "color": true
          },
          "numberOfItems": true,
          "numberOfTracks": true,
          "numberOfEpisodes": true,
          "isOwner": true
        }
      },
      "basePermission": true,
      "userCapabilities": true,
      "extension": [
        "ROOTLISTABILITY_TRAIT",
        "VISUAL_IDENTITY_TRAIT",
        "AUTO_LENS"
      ],
      "lenses": true,
      "lengthIgnoringTextFilter": true,
      "numberOfItemsPerLinkType": true,
      "availableSignals": true,
      "unrangedLength": true
    },
    "track": {
      "track": {
        "hasLyrics": true,
        "link": true,
        "name": true,
        "length": true,
        "playable": true,
        "isAvailableInMetadataCatalogue": true,
        "locallyPlayable": true,
        "playableLocalTrack": true,
        "discNumber": true,
        "trackNumber": true,
        "isExplicit": true,
        "previewId": true,
        "isLocal": true,
        "isPremiumOnly": true,
        "playableTrackLink": true,
        "popularity": true,
        "is19PlusOnly": true,
        "trackDescriptors": true,
        "extension": [
          "IDENTITY_TRAIT",
          "VIDEO_ASSOCIATIONS",
          "AUDIO_ASSOCIATIONS",
          "ORIGINAL_VIDEO",
          "CONSUMPTION_EXPERIENCE_TRAIT",
          "PUBLISHING_METADATA_TRAIT"
        ]
      },
      "rowId": true,
      "addTime": true,
      "formatListAttributes": true,
      "addedBy": {
        "username": true,
        "link": true,
        "name": true,
        "image": true,
        "thumbnail": true,
        "color": true
      },
      "album": {
        "album": {
          "link": true,
          "name": true,
          "covers": true
        },
        "artist": {
          "link": true,
          "name": true
        }
      },
      "artist": {
        "link": true,
        "name": true
      }
    },
    "episode": {
      "episode": {
        "link": true,
        "length": true,
        "name": true,
        "description": true,
        "publishDate": true,
        "covers": true,
        "mediaTypeEnum": true,
        "number": true,
        "isExplicit": true,
        "type": true,
        "extension": [
          "PODCAST_SUBSCRIPTIONS",
          "GATED_ENTITY_RELATIONS",
          "VISUAL_IDENTITY_TRAIT",
          "IDENTITY_TRAIT",
          "ENTITY_TYPE_TRAIT",
          "CONTENT_EXPERIENCE_TRAIT",
          "SHARE_TRAIT"
        ],
        "is19PlusOnly": true,
        "isBookChapter": true,
        "isPodcastShort": true
      },
      "rowId": true,
      "addTime": true,
      "formatListAttributes": true,
      "playedState": {
        "timeLeft": true,
        "isPlayed": true,
        "playable": true
      },
      "addedBy": {
        "username": true,
        "link": true,
        "name": true,
        "image": true,
        "thumbnail": true,
        "color": true
      },
      "show": {
        "link": true,
        "name": true,
        "publisher": true,
        "covers": true,
        "isBook": true
      },
      "signals": true,
      "isRecommendation": true
    },
    "item": {
      "uri": true,
      "extensionPolicy": [
        {
          "linkType": "SHOW",
          "extension": "SHOW_ACCESS"
        },
        {
          "linkType": "SHOW",
          "extension": "COVER_IMAGE"
        },
        {
          "linkType": "SHOW",
          "extension": "AUDIOBOOK_SPECIFICS"
        },
        {
          "linkType": "SHOW",
          "extension": "PLAYABILITY"
        },
        {
          "linkType": "SHOW",
          "extension": "SHOW_V4"
        },
        {
          "linkType": "SHOW",
          "extension": "HTML_DESCRIPTION"
        },
        {
          "linkType": "SHOW",
          "extension": "PODCAST_RATING"
        },
        {
          "linkType": "SHOW",
          "extension": "AUDIOBOOK_GENRE"
        },
        {
          "linkType": "KALLAX",
          "extension": "IDENTITY_TRAIT"
        },
        {
          "linkType": "KALLAX",
          "extension": "VISUAL_IDENTITY_TRAIT"
        },
        {
          "linkType": "KALLAX",
          "extension": "CONSUMPTION_EXPERIENCE_TRAIT"
        },
        {
          "linkType": "PODCAST_CHAPTER",
          "extension": "IDENTITY_TRAIT"
        },
        {
          "linkType": "PODCAST_CHAPTER",
          "extension": "VISUAL_IDENTITY_TRAIT"
        },
        {
          "linkType": "PODCAST_CHAPTER",
          "extension": "CONSUMPTION_EXPERIENCE_TRAIT"
        },
        {
          "linkType": "PODCAST_CHAPTER",
          "extension": "PUBLISHING_METADATA_TRAIT"
        },
        {
          "linkType": "PODCAST_CHAPTER",
          "extension": "PODCAST_SUBSCRIPTIONS"
        },
        {
          "linkType": "CLIP",
          "extension": "IDENTITY_TRAIT"
        },
        {
          "linkType": "CLIP",
          "extension": "VISUAL_IDENTITY_TRAIT"
        },
        {
          "linkType": "CLIP",
          "extension": "CONSUMPTION_EXPERIENCE_TRAIT"
        }
      ],
      "collectionState": true
    }
  },
  "pagingPlaylist": {
    "extension": [
      "AUTO_LENS"
    ],
    "unrangedLength": true
  }
}
''';
