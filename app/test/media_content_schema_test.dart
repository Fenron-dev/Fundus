import 'package:flutter_test/flutter_test.dart';
import 'package:fundus/library/media_content_schema.dart';

void main() {
  test('video definitions distinguish film files from series episodes', () {
    expect(FundusMediaTypes.film.contentTabLabel, 'Dateien');
    expect(FundusMediaTypes.series.contentTabLabel, 'Folgen');
    expect(FundusMediaTypes.series.hasLevel('season'), isTrue);
    expect(FundusMediaTypes.series.hasLevel('episode'), isTrue);
  });

  test('work resolver maps provider kinds and style/sensitivity facets', () {
    expect(
      FundusMediaTypeRegistry.forWork(kind: 'movie'),
      same(FundusMediaTypes.film),
    );
    expect(
      FundusMediaTypeRegistry.forWork(kind: 'tv', contentStyle: 'anime'),
      same(FundusMediaTypes.animeSeries),
    );
    expect(
      FundusMediaTypeRegistry.forWork(
        kind: 'video',
        contentSensitivity: 'adult_explicit',
      ),
      same(FundusMediaTypes.hhhSeries),
    );
    expect(
      FundusMediaTypeRegistry.forWork(kind: 'ttrpg_product')?.contentTabLabel,
      'Dateien',
    );
  });

  test('manga arcs are optional while chapters and pages remain stable', () {
    final arc = FundusMediaTypes.manga.level('arc');
    expect(arc, isNotNull);
    expect(arc!.optional, isTrue);
    expect(arc.virtual, isFalse);
    expect(FundusMediaTypes.manga.hasLevel('chapter'), isTrue);
    expect(FundusMediaTypes.manga.hasLevel('page'), isTrue);
  });

  test(
    'all media types expose universal detail sections and registry lookup',
    () {
      for (final definition in FundusMediaTypeRegistry.all) {
        expect(definition.detailTabs, contains(FundusDetailTab.files));
        expect(definition.detailTabs, contains(FundusDetailTab.notes));
        expect(definition.detailTabs, contains(FundusDetailTab.similar));
        expect(definition.detailTabs, contains(FundusDetailTab.devices));
        expect(FundusMediaTypeRegistry.byId(definition.id), same(definition));
      }
    },
  );

  test('adult HHH definitions are marked for the visibility policy', () {
    expect(
      FundusMediaTypes.hhhFilm.sensitivity,
      FundusContentSensitivity.adult,
    );
    expect(
      FundusMediaTypes.hhhSeries.sensitivity,
      FundusContentSensitivity.adult,
    );
    expect(
      FundusMediaTypes.animeFilm.sensitivity,
      FundusContentSensitivity.normal,
    );
  });

  test('player capabilities follow the media type', () {
    expect(
      FundusMediaTypes.film.playerCapabilities,
      contains(FundusPlayerCapability.subtitles),
    );
    expect(
      FundusMediaTypes.manga.playerCapabilities,
      contains(FundusPlayerCapability.zoom),
    );
    expect(FundusMediaTypes.archive.playerCapabilities, isEmpty);
  });
}
