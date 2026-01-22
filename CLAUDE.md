# RTK (Rust Token Killer) - Instructions pour Claude

## RÈGLE OBLIGATOIRE : Utiliser rtk au lieu des commandes Unix standard

Pour minimiser la consommation de tokens et optimiser les échanges, tu DOIS utiliser `rtk` au lieu des commandes Unix classiques.

### Substitutions obligatoires

| ❌ Ne PAS utiliser | ✅ Utiliser à la place |
|-------------------|----------------------|
| `ls`, `ls -la`, `find` | `rtk ls <path>` |
| `cat`, `head`, `tail` | `rtk read <file>` |
| `cat` pour comprendre du code | `rtk read <file> -l aggressive` |

### Commandes rtk disponibles

```bash
# Lister un répertoire (filtre automatiquement .git, node_modules, target, etc.)
rtk ls <path>
rtk ls <path> -d 3          # Profondeur max 3
rtk ls <path> -f flat       # Format plat
rtk ls <path> -f json       # Format JSON

# Lire un fichier avec filtrage intelligent
rtk read <file>                    # Mode minimal (supprime commentaires)
rtk read <file> -l none            # Pas de filtrage
rtk read <file> -l aggressive      # Garde uniquement signatures/imports
rtk read <file> -l aggressive -m 50  # Max 50 lignes avec smart truncate
rtk read <file> -n                 # Avec numéros de ligne

# Résumé AI en 2 lignes (nécessite téléchargement modèle ~2GB)
rtk smart <file>
```

### Gains mesurés

- `rtk ls` vs `ls -la` : **-82% de tokens**
- `rtk read -l minimal` : **-18% de tokens**
- `rtk read -l aggressive` : **-74% de tokens**

### Exemples d'utilisation

```bash
# Explorer un projet
rtk ls .

# Comprendre rapidement un fichier
rtk read src/main.rs -l aggressive

# Lire un fichier de config en entier
rtk read Cargo.toml -l none

# Voir les 30 premières lignes importantes
rtk read src/lib.rs -l aggressive -m 30
```

## Pourquoi utiliser rtk ?

1. **Moins de tokens** = conversations plus longues
2. **Filtrage intelligent** = focus sur le code important
3. **Pas de bruit** = ignore automatiquement .git, node_modules, __pycache__, etc.
