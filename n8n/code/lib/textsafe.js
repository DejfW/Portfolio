// Filtr tekstu trafiającego do klienta (wstępy pisane przez AI, etykiety pozycji). Odrzuca adresy i linki w każdej
// formie (schemat, www, domena bez schematu, e-mail), znaki formatowania oraz frazy typowe dla odmowy modelu.
const looksUnsafe = (t) => {
  // NFKC zamienia znaki pełnej szerokości, a kropki ideograficzne (U+3002, U+FF61) sprowadzamy ręcznie
  const s = String(t || '').normalize('NFKC').replace(/[\u3002\uFF61]/g, '.');
  return /https?:|\/\/|www\.|@|[\p{L}0-9-]{2,}\.[a-z]{2,}\b/iu.test(s) || /[<>{}\[\]*#`]/.test(s);
};
const looksRefusal = (t) => /przepraszam|nie mog[ęe]|odmawiam|nie jestem w stanie|jako (model|asystent|ai)|narusza|zasad(y|ach|ami) bezpiecze|podaj inne/i.test(String(t || ''));
