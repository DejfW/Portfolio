// Wybiera trasę dla każdej odebranej wiadomości. Filtrowanie maili po liście dozwolonych adresów robi baza
// (claim_deliveries), więc tutaj trafiają tylko wiadomości, które wolno wysłać.
return $input.all().map(({ json: m }) => {
  const route = m.channel === 'slack' ? 'slack:send' : m.channel === 'email' ? 'email:send' : 'skip';
  return { json: { ...m, route } };
});
