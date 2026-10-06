/*
 * fontmap.js — shared (Node + browser) tables that turn Roblox fonts into web fonts.
 *
 * A Roblox FontFace looks like {family:"rbxasset://fonts/families/Oswald.json", weight:"Bold", style:"Normal"}.
 * We reduce the family to a lowercase key ("oswald") and map it to a Google Fonts family.
 * Legacy Enum.Font values (the old `Font` property, or rich-text face="GothamBold") map to key+weight+style.
 */
(function (root) {
  'use strict';

  // roblox family key -> Google Fonts family (stand-ins where Roblox's font is not on Google Fonts)
  const FAMILY = {
    gothamssm: 'Montserrat', gotham: 'Montserrat',
    sourcesanspro: 'Source Sans 3', sourcesans: 'Source Sans 3',
    buildersans: 'Inter', buildersansmedium: 'Inter', buildersansbold: 'Inter', buildersansextrabold: 'Inter',
    fredokaone: 'Fredoka One', fredoka: 'Fredoka',
    oswald: 'Oswald', creepster: 'Creepster', specialelite: 'Special Elite', inconsolata: 'Inconsolata',
    fondamento: 'Fondamento', permanentmarker: 'Permanent Marker', amaticsc: 'Amatic SC',
    arial: 'Arimo', legacyarial: 'Arimo', arimo: 'Arimo', balthazar: 'Balthazar', bangers: 'Bangers',
    comicneueangular: 'Comic Neue', comicneue: 'Comic Neue', denkone: 'Denk One', grenze: 'Grenze',
    grenzegotisch: 'Grenze Gotisch', indieflower: 'Indie Flower', josefinsans: 'Josefin Sans', jura: 'Jura',
    kalam: 'Kalam', luckiestguy: 'Luckiest Guy', merriweather: 'Merriweather', michroma: 'Michroma',
    nunito: 'Nunito', patrickhand: 'Patrick Hand', roboto: 'Roboto', robotocondensed: 'Roboto Condensed',
    robotomono: 'Roboto Mono', sarpanch: 'Sarpanch', titilliumweb: 'Titillium Web', ubuntu: 'Ubuntu',
    pressstart2p: 'Press Start 2P', guru: 'EB Garamond', accanthisadfstd: 'EB Garamond',
    zekton: 'Orbitron', highwaygothic: 'Overpass', notosans: 'Noto Sans', bodoni: 'Libre Bodoni',
    montserrat: 'Montserrat', inter: 'Inter',
  };

  // Google family -> available weights / italic (avoids probing the API; unknown families get probed)
  const R = (a, b) => { const o = []; for (let w = a; w <= b; w += 100) o.push(w); return o; };
  const GOOGLE = {
    'Montserrat': { w: R(100, 900), i: true }, 'Oswald': { w: R(200, 700) }, 'Creepster': { w: [400] },
    'Special Elite': { w: [400] }, 'Inconsolata': { w: R(200, 900) }, 'Source Sans 3': { w: R(200, 900), i: true },
    'Inter': { w: R(100, 900), i: true }, 'Fredoka One': { w: [400] }, 'Fredoka': { w: R(300, 700) },
    'Fondamento': { w: [400], i: true }, 'Permanent Marker': { w: [400] }, 'Amatic SC': { w: [400, 700] },
    'Arimo': { w: R(400, 700), i: true }, 'Balthazar': { w: [400] }, 'Bangers': { w: [400] },
    'Comic Neue': { w: [300, 400, 700], i: true }, 'Denk One': { w: [400] }, 'Grenze': { w: R(100, 900), i: true },
    'Grenze Gotisch': { w: R(100, 900) }, 'Indie Flower': { w: [400] }, 'Josefin Sans': { w: R(100, 700), i: true },
    'Jura': { w: R(300, 700) }, 'Kalam': { w: [300, 400, 700] }, 'Luckiest Guy': { w: [400] },
    'Merriweather': { w: R(300, 900), i: true }, 'Michroma': { w: [400] }, 'Nunito': { w: R(200, 900), i: true },
    'Patrick Hand': { w: [400] }, 'Roboto': { w: R(100, 900), i: true }, 'Roboto Condensed': { w: R(100, 900), i: true },
    'Roboto Mono': { w: R(100, 700), i: true }, 'Sarpanch': { w: R(400, 900) },
    'Titillium Web': { w: [200, 300, 400, 600, 700, 900], i: true }, 'Ubuntu': { w: [300, 400, 500, 700], i: true },
    'Press Start 2P': { w: [400] }, 'EB Garamond': { w: R(400, 800), i: true }, 'Orbitron': { w: R(400, 900) },
    'Overpass': { w: R(100, 900), i: true }, 'Noto Sans': { w: R(100, 900), i: true },
    'Libre Bodoni': { w: R(400, 700), i: true },
  };

  const FALLBACK_FAMILY = 'Inter';

  const WEIGHT = {
    thin: 100, extralight: 200, ultralight: 200, light: 300, regular: 400, normal: 400, book: 400,
    medium: 500, semibold: 600, demibold: 600, bold: 700, extrabold: 800, ultrabold: 800, heavy: 900, black: 900,
  };

  // Enum.Font name -> [family key, weight, italic]
  const ENUM_FONT = {
    Legacy: ['legacyarial', 400], Arial: ['arial', 400], ArialBold: ['arial', 700],
    SourceSans: ['sourcesanspro', 400], SourceSansBold: ['sourcesanspro', 700], SourceSansSemibold: ['sourcesanspro', 600],
    SourceSansLight: ['sourcesanspro', 300], SourceSansItalic: ['sourcesanspro', 400, true],
    Bodoni: ['accanthisadfstd', 400], Garamond: ['guru', 400], Cartoon: ['comicneueangular', 400],
    Code: ['inconsolata', 400], Highway: ['highwaygothic', 400], SciFi: ['zekton', 400], Arcade: ['pressstart2p', 400],
    Fantasy: ['fondamento', 400], Antique: ['accanthisadfstd', 400],
    Gotham: ['gothamssm', 400], GothamMedium: ['gothamssm', 500], GothamSemibold: ['gothamssm', 600],
    GothamBold: ['gothamssm', 700], GothamBlack: ['gothamssm', 900],
    AmaticSC: ['amaticsc', 400], Bangers: ['bangers', 400], Creepster: ['creepster', 400], DenkOne: ['denkone', 400],
    Fondamento: ['fondamento', 400], FredokaOne: ['fredokaone', 400], GrenzeGotisch: ['grenzegotisch', 400],
    IndieFlower: ['indieflower', 400], JosefinSans: ['josefinsans', 400], Jura: ['jura', 400], Kalam: ['kalam', 400],
    LuckiestGuy: ['luckiestguy', 400], Merriweather: ['merriweather', 400], Michroma: ['michroma', 400],
    Nunito: ['nunito', 400], Oswald: ['oswald', 400], PatrickHand: ['patrickhand', 400],
    PermanentMarker: ['permanentmarker', 400], Roboto: ['roboto', 400], RobotoCondensed: ['robotocondensed', 400],
    RobotoMono: ['robotomono', 400], Sarpanch: ['sarpanch', 400], SpecialElite: ['specialelite', 400],
    TitilliumWeb: ['titilliumweb', 400], Ubuntu: ['ubuntu', 400],
    BuilderSans: ['buildersans', 400], BuilderSansMedium: ['buildersans', 500], BuilderSansBold: ['buildersans', 700],
    BuilderSansExtraBold: ['buildersans', 800], Unknown: ['sourcesanspro', 400],
  };

  /** "rbxasset://fonts/families/GothamSSm.json" | "GothamSSm" | "Gotham SSm" -> "gothamssm" */
  function familyKey(family) {
    if (typeof family !== 'string' || !family) return 'sourcesanspro';
    let s = family;
    const m = /families\/([^/]+?)(\.json)?$/i.exec(s);
    if (m) s = m[1];
    else if (/^rbxassetid:\/\//i.test(s) || /^rbxasset:\/\//i.test(s)) return s.toLowerCase(); // cloud / unknown font
    return s.toLowerCase().replace(/[^a-z0-9]/g, '');
  }

  function weightNum(w, dflt) {
    if (typeof w === 'number' && isFinite(w)) return Math.max(100, Math.min(900, Math.round(w / 100) * 100));
    if (w && typeof w === 'object' && w.name) w = w.name;
    if (typeof w === 'string') {
      const n = parseInt(w, 10);
      if (!isNaN(n)) return weightNum(n, dflt);
      const k = w.replace(/^.*\./, '').toLowerCase().replace(/[^a-z]/g, '');
      if (WEIGHT[k]) return WEIGHT[k];
    }
    return dflt === undefined ? 400 : dflt;
  }

  /** Decode a FontFace value (or a legacy Enum.Font) into {key, weight, italic}. */
  function decodeFont(fontFace, legacyFont) {
    if (fontFace && typeof fontFace === 'object' && (fontFace.family || fontFace.Family)) {
      const st = fontFace.style && typeof fontFace.style === 'object' ? fontFace.style.name : fontFace.style;
      return {
        key: familyKey(fontFace.family || fontFace.Family),
        weight: weightNum(fontFace.weight, 400),
        italic: /italic/i.test(String(st || '')),
      };
    }
    let name = legacyFont;
    if (name && typeof name === 'object') name = name.name;
    if (typeof name === 'string') {
      name = name.replace(/^.*\./, '');
      const e = ENUM_FONT[name];
      if (e) return { key: e[0], weight: e[1], italic: !!e[2] };
      return { key: familyKey(name), weight: 400, italic: false };
    }
    return { key: 'sourcesanspro', weight: 400, italic: false };
  }

  /** Rich-text face="X" may be an Enum.Font name or a family name. */
  function decodeFace(face) {
    const e = ENUM_FONT[face];
    if (e) return { key: e[0], weight: e[1], italic: !!e[2] };
    return { key: familyKey(face), weight: null, italic: false };
  }

  /** CSS font matching (CSS Fonts 4 §5.2) for a requested weight among available ones. */
  function matchWeight(avail, w) {
    if (!avail || !avail.length) return 400;
    if (avail.includes(w)) return w;
    const asc = avail.slice().sort((a, b) => a - b);
    const below = asc.filter((x) => x < w).reverse();
    const above = asc.filter((x) => x > w);
    if (w >= 400 && w <= 500) {
      const upTo500 = above.filter((x) => x <= 500);
      if (upTo500.length) return upTo500[0];
      if (below.length) return below[0];
      return above[0];
    }
    if (w < 400) return below.length ? below[0] : above[0];
    return above.length ? above[0] : below[0];
  }

  const api = { FAMILY, GOOGLE, FALLBACK_FAMILY, WEIGHT, ENUM_FONT, familyKey, weightNum, decodeFont, decodeFace, matchWeight };
  if (typeof module !== 'undefined' && module.exports) module.exports = api;
  else root.RBXFONTS = api;
})(typeof window !== 'undefined' ? window : globalThis);
