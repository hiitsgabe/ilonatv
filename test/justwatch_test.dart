import 'package:ilonatv/data/justwatch.dart';
import 'package:ilonatv/data/media.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  test('services: the country\'s subscription services in JustWatch\'s order, '
      'with logos and short names; JSON round trip', () async {
    final net = fakePost({'graphql': 'jw_packages.json'});
    final list = await JustWatchClient(net.call).services('CA');
    final (uri, body) = net.calls.single;
    expect(uri.toString(), 'https://apis.justwatch.com/graphql');
    expect(body['operationName'], 'GetProviders');
    expect(body['variables'], {'country': 'CA'});
    // Not the Apple TV store, JustWatch TV Free, Tubi nor Netflix Kids.
    expect([for (final p in list) p.id], [350, 119, 337, 8, 531, 230, 11, 283]);
    expect(list.first.name, 'Apple TV');
    expect(list.first.key, 'atp');
    expect(
      list.first.logoUrl,
      'https://images.justwatch.com/icon/357333613/s100/appletvplus.png',
    );
    final again = WatchProvider.fromJson(list[3].toJson());
    expect([again.id, again.name, again.key], [8, 'Netflix', 'nfx']);
  });

  test('services: after the known ones, the country\'s own subscriptions; '
      'no store, no free-only, nothing ad-funded', () async {
    final net = fakePost({'graphql': 'jw_packages_jp.json'});
    final list = await JustWatchClient(net.call).services('JP');
    expect(net.calls.single.$2['query'], contains('monetizationTypes'));
    expect(
      [for (final p in list) p.id],
      [8, 9, 350, 337, 15, 84, 190, 475, 546],
    );
  });

  test('popularOn: what is popular on a service, in its order, as TMDB items '
      'with JustWatch\'s pictures and TMDB\'s genre names; no TMDB id, no '
      'item', () async {
    final net = fakePost({'graphql': 'jw_popular_nfx_show.json'});
    final items = await JustWatchClient(net.call).popularOn(
      'CA',
      'en',
      MediaType.series,
      {18: 'Drama', 10759: 'Action & Adventure'},
      services: ['nfx'],
    );
    final body = net.calls.single.$2;
    expect(body['operationName'], 'GetPopularTitles');
    expect(body['variables'], {
      'country': 'CA',
      'language': 'en',
      'first': 25,
      'filter': {
        'packages': ['nfx'],
        'objectTypes': ['SHOW'],
      },
    });
    expect(items.map((i) => i.title), [
      'Black Doves',
      'The Body',
      'Below',
      'Ghosts',
      'The Diplomat',
    ]);
    final first = items.first;
    expect(first.type, MediaType.series);
    expect(first.id, '225385');
    expect(first.year, 2024);
    expect(first.genre, 'Action & Adventure');
    expect(first.rating, isNotNull);
    expect(
      first.posterUrl,
      'https://images.justwatch.com/poster/323408766/s332/black-doves.jpg',
    );
    expect(
      first.backdropUrl,
      'https://images.justwatch.com/backdrop/357114533/s1440/black-doves.jpg',
    );
    expect(first.overview, startsWith('When a spy'));
  });

  test('popular: the country\'s popular films and series together, each of '
      'its kind', () async {
    final net = fakePost({'graphql': 'jw_popular_ca.json'});
    final items = await JustWatchClient(net.call)
        .popular('CA', 'en', {18: 'Drama'}, {18: 'Drama', 35: 'Comedy'});
    final variables = net.calls.single.$2['variables'] as Map;
    expect(variables['filter'], {
      'objectTypes': ['MOVIE', 'SHOW'],
    });
    expect(variables['first'], 25);
    expect(items, hasLength(7));
    expect(items.last.type, MediaType.movie);
    expect(items.first.type, MediaType.series);
    expect(items.every((i) => i.backdropUrl != null), isTrue);
  });

  test('popularOn: a film asks for MOVIE', () async {
    final net = fakePost({'graphql': 'jw_popular_nfx_show.json'});
    await JustWatchClient(net.call)
        .popularOn('BR', 'pt', MediaType.movie, {}, services: ['prv']);
    final filter = net.calls.single.$2['variables']['filter'] as Map;
    expect(filter['objectTypes'], ['MOVIE']);
    expect(net.calls.single.$2['variables']['language'], 'pt');
  });

  test('genres: JustWatch\'s list, whole, by name, in the language; JSON '
      'round trip', () async {
    final net = fakePost({'graphql': 'jw_genres.json'});
    final list = await JustWatchClient(net.call).genres('pt');
    expect(net.calls.single.$2['operationName'], 'GetGenres');
    expect(net.calls.single.$2['variables'], {'language': 'pt'});
    expect(list, hasLength(19));
    // By name, so Horror and Documentary are where the eye looks for them.
    final names = [for (final g in list) g.name];
    expect(names, [...names]..sort());
    expect((list.first.code, list.first.name), ('act', 'Action & Adventure'));
    expect(list.last.name, 'Western');
    final again = Genre.fromJson(list.first.toJson());
    expect((again.code, again.name), ('act', 'Action & Adventure'));
  });

  test('popularOn: the filter carries the services and the genre only when '
      'given', () async {
    final net = fakePost({'graphql': 'jw_popular_nfx_show.json'});
    final c = JustWatchClient(net.call);
    await c.popularOn('CA', 'en', MediaType.series, {}, services: ['nfx']);
    await c.popularOn('CA', 'en', MediaType.series, {}, genre: 'cmy');
    await c.popularOn(
      'CA',
      'en',
      MediaType.movie,
      {},
      services: ['nfx'],
      genre: 'cmy',
    );
    await c.popularOn(
      'CA',
      'en',
      MediaType.movie,
      {},
      services: ['nfx', 'dnp'],
    );
    expect(
      [for (final (_, b) in net.calls) b['variables']['filter']],
      [
        {
          'packages': ['nfx'],
          'objectTypes': ['SHOW'],
        },
        {
          'genres': ['cmy'],
          'objectTypes': ['SHOW'],
        },
        {
          'packages': ['nfx'],
          'genres': ['cmy'],
          'objectTypes': ['MOVIE'],
        },
        {
          'packages': ['nfx', 'dnp'],
          'objectTypes': ['MOVIE'],
        },
      ],
    );
  });
}
