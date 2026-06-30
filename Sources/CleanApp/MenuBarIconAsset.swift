import AppKit

/// Custom menu-bar glyph (squeegee), embedded as a base64 PNG so no SPM
/// resource bundle is needed. Rendered as a template image so it adopts the
/// menu bar's light/dark tint automatically.
enum MenuBarIcon {
    /// Template NSImage of the app glyph. `isTemplate = true` → menu-bar tinted.
    static func image(size: CGFloat = 18) -> NSImage {
        let img = NSImage(data: Data(base64Encoded: base64PNG)!) ?? NSImage()
        img.isTemplate = true
        img.size = NSSize(width: size, height: size)
        return img
    }

    private static let base64PNG = "iVBORw0KGgoAAAANSUhEUgAAADYAAAA2CAYAAACMRWrdAAAFLElEQVR4nO2ZbYhVVRSG33PuzJRZTZllWUj0ozKiol9GVBT9ij6gHxZGYZklIkhRSEbFRA4YSh+KlZWlaVpS2ScTE2hoSfZBYYZE9cegJIvScmp0ZmLDu+Dl5czYvd25ngt3wWbfe8+6e69nr73XXnsfoCUtaUnZpY31jQA2A5grv2docqhbABwEMMRyXzPDtbGeQZgENgCgn98faka4NtZ3EOKAwKX6H9YPU6/SDHA569k0Pjy0HcCFAHr5vY91dzPA5azvNKivAEzks6ML4BaWGS5jPRbAPllTuwEcx2cdrMcA6DG4RWWGy1leprF/02thdE7DkxwB4B3q7Wf9eFnhMpZk9AYLFEsL4JIH3zS4pWWGi8j4mhn9VAFc0nt9GL3SweU0KBn2qhn9rOiE4aleb3rLra3SSE6DdM2F0SsK4NLntSPolXLNZQBeMqNXFsClstr0Vh0CrnK4spdM9rcXLcSvEaCK6K00ONULnVJIJgY9L1tBqtfZmnS9/QV66r1LAMwBcKz0ddjgPjC49RZIQm+5wYVegJ0ubaSBALeayFUbJtHhxTRGs/03ALTzucItMzjVO5WZTfp9sfXVUM/FOkkp1h4aNCij/pakXRXZ65YYnOqdDeBaCSDTeKjV/hoGdjyAX+XgqRnKu5xODveYwSW9I639WdLeEmkja9RUvEwM+F48EtGyh4mywy0yuB4m3R2cuvfw9z9ZL2sEXC71Zk7BiHZJHjW4XhrtcAsL9I7iszGNzmDCqGMKkuMpAt1t57iNPL853AKD28i2Y1asGyaDyUZj+qXQ/JkZtEB0IhjMZTAJ8A9lj1K4Lmsr6XWK3uoCuEq9oS4CsMs8FeFZ95yzeKWw2zy3xYwOAx80uC1yqM0lg/nLAkrNEhttkqnS8ADrOQY1lp32id5BltgKtjKaBlz8d75t9lsBjBM7Vkig+uT/QOkinWe3VH8AuIbPOqiXptnHBu4lvLwNwAkFcPMMbhuA8QKXrvpeAXBurVAVqZ+xzr4DcAGft8uUet+m0yZ69HrWmwzucwAnFsBFqFe9k1AHiQ7GFVzUpPB+ikCF7guml0a+SO61QfoSwIQCuLsM7gvqRZ9Vnwyi4TN5f6hGrJEMQY14xKJWt+loDXpPjd4ug1WRqDrfAkaX2Vg11OUF0SwZH5KL7mzzVBw6iw6MmSS9swxuB4DTRHcSA8SArOurBb7qyDddYAbZ6AxpMBOo68yjveKZkTbQ+P9Mg9vJ6ZbKTgtWt8ugVh35uqyxXwBcacbEAEzhFDkgN8SdVZyMo71bbWZ8wzIkv023vg8peie4ykY/NT55GKgzAPxMj6byI6dODFQtr6Z0QFOJlx43U6e9WqgJTGE8GR1vnecSKXeIIfv4gkLbrEai/ZtkoKJMM53/DHUegG/NU88VeCimV4ftRWlhX1Vt5yPA3cCBSkeVqbW2my5OfrcpcL+BxOcAXGueva0OUCHRxyQm2TXNgLRn/CSpT5+43SNaGL3Y9qoH7Hk9RNdnXksDT4qn9tB7RUbGgr3bPPX0MPr1fMtTk+ySU2/sUbHbF817XYNvy/Qs1VU1JJT2c077KAXUpQwSsZ98ymNJ6W5xQ/SsdA6NbLeUZzJvn+L48YO8oi0lFJhRD9rtj8rJPJrERvmbnH/qdiQfDZlpOdoT9NxE7ktfy/MUYK7g/xp+3VytpFF/z/Kx5Jm9ktKER1NG0BRQ4Frq5PXy0DBlr2TUTQEFC9Mpe/iIdxj93ArSmer8ZlhTLWlJSzDq8i+L9wa8aHU/4wAAAABJRU5ErkJggg=="
}
