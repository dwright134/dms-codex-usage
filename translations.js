.pragma library

var strings = {
    "Resetting...": {
        fr: "Réinitialisation...",
        es: "Restableciendo..."
    }
}

function tr(key, lang) {
    if (!lang || lang === "en" || !strings[key] || !strings[key][lang])
        return key
    return strings[key][lang]
}
