#!/usr/bin/env bash
# calc_protein_mass.sh
# Calculates average and monoisotopic mass for each entry in a protein FASTA file.
# See calc_protein_mass_README.md for mass tables and citations.
#
# Usage:  ./calc_protein_mass.sh <protein.fasta>
# Output: TSV to stdout — entry_id, description, length, avg_mass_Da, mono_mass_Da, nonCanon

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <protein.fasta>" >&2
    exit 1
fi

FASTA="$1"

if [[ ! -f "$FASTA" ]]; then
    echo "Error: file not found: $FASTA" >&2
    exit 1
fi

awk '
BEGIN {
    # ── Monoisotopic residue masses (Da) ────────────────────────────────────
    # Source: Unimod database (https://www.unimod.org)
    # Underlying atomic masses from NIST (https://www.nist.gov/pml/atomic-weights-and-isotopic-compositions-relative-atomic-masses)
    mono["A"] = 71.03711
    mono["R"] = 156.10111
    mono["N"] = 114.04293
    mono["D"] = 115.02694
    mono["C"] = 103.00919
    mono["E"] = 129.04259
    mono["Q"] = 128.05858
    mono["G"] = 57.02146
    mono["H"] = 137.05891
    mono["I"] = 113.08406
    mono["L"] = 113.08406
    mono["K"] = 128.09496
    mono["M"] = 131.04049
    mono["F"] = 147.06841
    mono["P"] = 97.05276
    mono["S"] = 87.03203
    mono["T"] = 101.04768
    mono["W"] = 186.07931
    mono["Y"] = 163.06333
    mono["V"] = 99.06841
    WATER_MONO = 18.01056

    # ── Average residue masses (Da) ─────────────────────────────────────────
    # Source: ExPASy ProtParam (https://web.expasy.org/protparam/)
    # Gasteiger E. et al., The Proteomics Protocols Handbook, Humana Press (2005)
    # Atomic weights: Meija J. et al., Pure Appl. Chem. 88(3):265-291 (2016)
    avg["A"] = 71.0788
    avg["R"] = 156.1875
    avg["N"] = 114.1038
    avg["D"] = 115.0886
    avg["C"] = 103.1388
    avg["E"] = 129.1155
    avg["Q"] = 128.1307
    avg["G"] = 57.0519
    avg["H"] = 137.1411
    avg["I"] = 113.1594
    avg["L"] = 113.1594
    avg["K"] = 128.1741
    avg["M"] = 131.1926
    avg["F"] = 147.1766
    avg["P"] = 97.1167
    avg["S"] = 87.0782
    avg["T"] = 101.1051
    avg["W"] = 186.2132
    avg["Y"] = 163.1760
    avg["V"] = 99.1326
    WATER_AVG = 18.01528

    entry_id = ""
    desc     = ""
    seq      = ""

    print "entry_id\tdescription\tlength\tavg_mass_Da\tmono_mass_Da\tnonCanon"
}

# ── Function: compute and print masses for the current entry ────────────────
function process_entry(    i, aa, m_sum, a_sum, canon_len, nc_str) {
    m_sum     = WATER_MONO
    a_sum     = WATER_AVG
    canon_len = 0
    nc_str    = ""

    for (i = 1; i <= length(seq); i++) {
        aa = substr(seq, i, 1)
        if (aa in mono) {
            m_sum += mono[aa]
            a_sum += avg[aa]
            canon_len++
        } else {
            if (nc_str != "") nc_str = nc_str "; "
            nc_str = nc_str aa i
        }
    }

    printf "%s\t%s\t%d\t%.5f\t%.5f\t%s\n",
        entry_id, desc, canon_len, a_sum, m_sum, nc_str

    if (nc_str != "") {
        print "WARNING: " entry_id " — non-canonical residues skipped: " nc_str > "/dev/stderr"
    }
}

# ── Parse FASTA ─────────────────────────────────────────────────────────────
/^>/ {
    if (entry_id != "") {
        process_entry()
    }
    header = substr($0, 2)
    sp     = index(header, " ")
    if (sp > 0) {
        entry_id = substr(header, 1, sp - 1)
        desc     = substr(header, sp + 1)
    } else {
        entry_id = header
        desc     = ""
    }
    seq = ""
    next
}

{
    seq = seq toupper($0)
}

END {
    if (entry_id != "") {
        process_entry()
    }
}
' "$FASTA"
