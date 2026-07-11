# TextMenuPlus 1.1.0 — Sous-menu "Text Style"

Validé par schlub51 le 2026-07-11.

## Objectif

Exposer les styles Unicode sûrs dans un sous-menu `Text Style`, redonner un rôle
clair à `Plain` (reset de style), sans réintroduire les bugs de détection
corrigés en 1.0.1.

## Décisions produit

- **13 styles exposés** (tous validés par le classifieur round-trip) :
  bold, italic, boldItalic, mono, serifBold, serifItalic, serifBoldItalic,
  script, scriptBold, gothic, gothicBold, hollow, circled.
- **`Plain` reste dans `Text Case`**, en premier item :
  Plain / Upper / Lower / Caps.
- **Nom du menu : `Text Style`**, cohérent avec `Text Case`.
- **Groupe sans-serif contextuel** : Bold, Italic et Bold Italic ne sont affichés
  que si l'app ne propose pas déjà le formatage natif (`toggleBoldface:`,
  `toggleItalics:` ou `toggleUnderline:`). Dans Notes, le menu commence donc à
  `Mono` pour éviter le doublon avec `Format`.
- **Aperçu vivant** : chaque entrée du menu est affichée dans son propre style
  (𝗕𝗼𝗹𝗱, 𝘐𝘵𝘢𝘭𝘪𝘤, 𝔊𝔬𝔱𝔥𝔦𝔠, ⒸⒾⓇⒸⓁⒺⒹ…). Pas d'icônes SF pour ces entrées :
  l'aperçu est l'explication.
- **Aperçu Circled en majuscules** : le titre affiché est généré depuis
  `CIRCLED` pour obtenir des bulles uniformes. Le rendu minuscule Unicode
  (`ⓒ`) ressemble à `©` ; c'est normal et ne doit pas être "corrigé".

## Structure du menu

```
Text Case (icône textformat)
├─ Plain
├─ Upper
├─ Lower
└─ Caps

Text Style (icône f.cursive, fallbacks character puis textformat)
├─ [inline, conditionnel] Bold · Italic · Bold Italic
├─ [inline] Mono
├─ [inline] Serif Bold · Serif Italic · Serif Bold Italic
├─ [inline] Script · Script Bold
├─ [inline] Gothic · Gothic Bold
└─ [inline] Hollow · Circled
```

Inséré dans `FSPrimaryInlineMenus` après le menu `Text Case`.

L'icône du sous-menu doit aussi être déclarée dans la table titre→symboles
`FSSymbolNamesForMenuTitle` (`Text Style` → `f.cursive`, fallbacks `character`
puis `textformat`) : `FSStyleMenuCell` masque volontairement les images natives
des cellules dont le titre n'est pas reconnu dans cette table.

## Condition technique préalable : correctif du plist

Le style `script` utilise 11 caractères de substitution partagés avec
`serifItalic`. Les remplacer par les caractères Unicode script dédiés :

| plain | actuel (serif italic) | correct (script) |
|-------|----------------------|------------------|
| B | 𝐵 | ℬ U+212C |
| E | 𝐸 | ℰ U+2130 |
| F | 𝐹 | ℱ U+2131 |
| H | 𝐻 | ℋ U+210B |
| I | 𝐼 | ℐ U+2110 |
| L | 𝐿 | ℒ U+2112 |
| M | 𝑀 | ℳ U+2133 |
| R | 𝑅 | ℛ U+211B |
| e | 𝑒 | ℯ U+212F |
| g | 𝑔 | ℊ U+210A |
| o | 𝑜 | ℴ U+2134 |

Après ce correctif : zéro ambiguïté croisée entre les 13 styles whitelistés.

## Moteur

- Toutes les commandes de style passent par le mécanisme générique existant :
  action `tmpTextMenuPlusApplyStyle:` + propertyList marqueur `style.<nom>`.
- La présence de formatage natif se détecte par action uniquement, jamais par
  titre localisé : `toggleBoldface:`, `toggleItalics:` ou `toggleUnderline:`.
  Cette détection est recalculée à chaque construction de menu, sans cache
  global.
- Les sélecteurs redondants `tmpTextMenuPlusBoldStyle/ItalicStyle/MonoStyle`
  sont supprimés (ainsi que leurs entrées dans `canPerformAction:`).
  `tmpTextMenuPlusApplyCombineStyle:` et `tmpTextMenuPlusSpongebob:` restent
  inertes (réservés à un futur chantier Text Effects).
- `FSStyleNameCanBeDetected` (whitelist de détection) passe de 4 à 13 noms :
  Upper/Lower/Caps préservent n'importe quel style exposé.
- Les styles interdits (russian, greek, smallCaps, copperplate, wide, circled
  filled, boxed, boxedFilled, zalgo, clap) restent hors whitelist et hors menu :
  rejetés par le classifieur (sorties ASCII, casses fusionnées, collisions).
  Leur table inverse reste disponible pour le nettoyage d'artefacts via Plain.

## Tests

`tests/style-roundtrip.py` étendu :
1. Round-trip apply→detect→plain pour chacun des 13 styles whitelistés.
2. Ambiguïté croisée entre styles whitelistés == 0 (échec sinon).
3. Anti-régressions conservées : MAJUSCULES jamais détectées comme style,
   Plain n'altère pas la casse, artefacts И/Д nettoyés.

## Livraison

- Version 1.1.0, branche dédiée, merge dans main après QA on-device de schlub51.
- Pas de publication sur le repo Sileo sans décision explicite de schlub51.
