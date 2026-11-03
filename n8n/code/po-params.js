// Parametry uruchomienia zamówień do hurtowni. Harmonogram działa zawsze; wywołanie przez webhook (/po-run)
// jest dozwolone tylko w trybie testowym (ALLOW_LLM_MOCK=1), więc z zewnątrz nikt nie wymusi tworzenia szkiców.
const i = $input.first().json;
const viaWebhook = i.headers !== undefined;
const allowed = !viaWebhook || i.allowMock === '1';
return [{ json: { viaWebhook, allowed } }];
