import 'package:flutter/material.dart';

class CelebrityEvent {
  final String headline;
  final int delta;
  final String timeAgo;
  final int sortOrder; // lower = more recent

  const CelebrityEvent({
    required this.headline,
    required this.delta,
    required this.timeAgo,
    required this.sortOrder,
  });
}

class Celebrity {
  final String id;
  final String name;
  final String initials;
  final Color avatarColor;
  final int currentScore;
  final List<CelebrityEvent> events;

  const Celebrity({
    required this.id,
    required this.name,
    required this.initials,
    required this.avatarColor,
    required this.currentScore,
    required this.events,
  });

  int get recentDelta => events.isNotEmpty ? events.first.delta : 0;
}

const kCelebrities = [
  Celebrity(
    id: 'alix-earle',
    name: 'Alix Earle',
    initials: 'AE',
    avatarColor: Color(0xFF00BCD4),
    currentScore: 87,
    events: [
      CelebrityEvent(
        headline:
            'Fan sympathy surge after Alex Cooper rivalry goes public — relatability scores soar across every platform',
        delta: 14,
        timeAgo: '2 days ago',
        sortOrder: 1,
      ),
      CelebrityEvent(
        headline:
            'GRWM TikTok hits 40M views in 48 hours; brand deal inquiries triple overnight',
        delta: 11,
        timeAgo: '1 week ago',
        sortOrder: 5,
      ),
    ],
  ),
  Celebrity(
    id: 'alex-cooper',
    name: 'Alex Cooper',
    initials: 'AC',
    avatarColor: Color(0xFF9C27B0),
    currentScore: 74,
    events: [
      CelebrityEvent(
        headline:
            'Podcast rivalry with Alix Earle divides the internet — fans publicly choosing sides in real time',
        delta: -8,
        timeAgo: '2 days ago',
        sortOrder: 2,
      ),
      CelebrityEvent(
        headline:
            'Landmark \$125M deal with SiriusXM reshapes the podcast industry; biggest creator contract of 2024',
        delta: 16,
        timeAgo: '3 weeks ago',
        sortOrder: 8,
      ),
    ],
  ),
  Celebrity(
    id: 'justin-bieber',
    name: 'Justin Bieber',
    initials: 'JB',
    avatarColor: Color(0xFF3F51B5),
    currentScore: 69,
    events: [
      CelebrityEvent(
        headline:
            'Cryptic Instagram post teases new music — highest engagement rate on his account in 3 years',
        delta: 9,
        timeAgo: '1 week ago',
        sortOrder: 6,
      ),
      CelebrityEvent(
        headline:
            'First public appearance after extended health hiatus sends fans into celebration worldwide',
        delta: 12,
        timeAgo: '3 weeks ago',
        sortOrder: 9,
      ),
    ],
  ),
  Celebrity(
    id: 'ishowspeed',
    name: 'IShowSpeed',
    initials: 'IS',
    avatarColor: Color(0xFFF44336),
    currentScore: 91,
    events: [
      CelebrityEvent(
        headline:
            'Named #3 most-watched streamer globally for the second consecutive month by StreamTracker',
        delta: 14,
        timeAgo: '2 weeks ago',
        sortOrder: 4,
      ),
      CelebrityEvent(
        headline:
            'Collab video with Cristiano Ronaldo surpasses 50M YouTube views in 72 hours — fastest ever for a streamer',
        delta: 19,
        timeAgo: '1 month ago',
        sortOrder: 11,
      ),
    ],
  ),
  Celebrity(
    id: 'donald-trump',
    name: 'Donald Trump',
    initials: 'DT',
    avatarColor: Color(0xFFFF8F00),
    currentScore: 93,
    events: [
      CelebrityEvent(
        headline:
            'Approval rating among core base hits highest point since first term, per latest national polling',
        delta: 8,
        timeAgo: '2 weeks ago',
        sortOrder: 3,
      ),
      CelebrityEvent(
        headline:
            'Won 2024 Presidential Election in historic comeback — global search interest peaks across 190 countries',
        delta: 24,
        timeAgo: '5 months ago',
        sortOrder: 13,
      ),
    ],
  ),
  Celebrity(
    id: 'kanye',
    name: 'Kanye West',
    initials: 'KW',
    avatarColor: Color(0xFF616161),
    currentScore: 41,
    events: [
      CelebrityEvent(
        headline:
            'New album rollout sparks widespread backlash following erratic social media activity over 72-hour period',
        delta: -9,
        timeAgo: '3 weeks ago',
        sortOrder: 7,
      ),
      CelebrityEvent(
        headline:
            'Adidas officially terminates \$1.5B partnership — largest brand divorce in music history',
        delta: -22,
        timeAgo: '8 months ago',
        sortOrder: 14,
      ),
    ],
  ),
  Celebrity(
    id: 'billie-eilish',
    name: 'Billie Eilish',
    initials: 'BE',
    avatarColor: Color(0xFF8BC34A),
    currentScore: 82,
    events: [
      CelebrityEvent(
        headline:
            'Oscars performance streamed by 85M viewers — worldwide trending across social platforms for 48 hours straight',
        delta: 10,
        timeAgo: '1 month ago',
        sortOrder: 10,
      ),
      CelebrityEvent(
        headline:
            'Hit Me Hard and Soft debuts #1 across 18 countries; critics call it her most complete work',
        delta: 13,
        timeAgo: '4 months ago',
        sortOrder: 12,
      ),
    ],
  ),
];
