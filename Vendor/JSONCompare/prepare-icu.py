from pathlib import Path
import re
import sys
src=Path(sys.argv[1])/'i18n'
root=Path(sys.argv[2])
root.mkdir(parents=True,exist_ok=True)
for stem in ['collationiterator','collationcompare']:
    for ext in ['h','cpp']:
        p=src/f'{stem}.{ext}'
        s=p.read_text().replace('CollationIterator','ExternalCollationIterator').replace('CollationCompare','ExternalCollationCompare').replace('SkippedState','ExternalSkippedState').replace('"collationiterator.h"','"externaliterator.h"').replace('"collationcompare.h"','"externalcompare.h"')
        s=re.sub(r'\bint32_t\b','int64_t',s)
        if stem=='collationiterator' and ext=='h':
            s=s.replace('#include "unicode/utypes.h"','#include "unicode/utypes.h"\n#include "DiskStorage.hpp"')
            s=s.replace('buffer[length++] = ce;','buffer.set(length++, ce);').replace('return buffer[i] = ce;','buffer.set(i, ce); return ce;').replace('return buffer[i];','return buffer[i];')
            s=s.replace('const int64_t *getCEs() const { return buffer.getAlias(); }','const int64_t *getCEs() const { throw std::runtime_error("unused contiguous CE API"); }')
            s=s.replace('MaybeStackArray<int64_t, INITIAL_CAPACITY> buffer;','DiskArray<int64_t> buffer;')
        if stem=='collationiterator' and ext=='cpp':
            start=s.index('UBool\nExternalCollationIterator::CEBuffer::ensureAppendCapacity(')
            end=s.index('// State of combining marks',start)
            s=s[:start]+'''UBool
ExternalCollationIterator::CEBuffer::ensureAppendCapacity(int64_t, UErrorCode &errorCode) {
    return U_SUCCESS(errorCode);
}

'''+s[end:]
            s=s.replace('UnicodeString oldBuffer;','DiskUTF16 oldBuffer;').replace('UnicodeString newBuffer;','DiskUTF16 newBuffer;')
            s=s.replace('pos < oldBuffer.length()', 'pos < static_cast<int64_t>(oldBuffer.length())')
            start=s.index('    // Collect digits.',s.index('ExternalCollationIterator::appendNumericCEs('))
            end=s.index('\n}\n',start)
            s=s[:start]+'''    if(!forward) throw std::runtime_error("unused backward numeric API");
    DiskArray<char> digits;
    for(;;) {
        digits.append(Collation::digitFromCE32(ce32));
        if(numCpFwd == 0) break;
        UChar32 c = nextCodePoint(errorCode);
        if(c < 0) break;
        ce32 = data->getCE32(c);
        if(ce32 == Collation::FALLBACK_CE32) ce32 = data->base->getCE32(c);
        if(!Collation::hasCE32Tag(ce32, Collation::DIGIT_TAG)) {
            backwardNumCodePoints(1, errorCode);
            break;
        }
        if(numCpFwd > 0) --numCpFwd;
    }
    uint64_t pos = 0;
    do {
        while(pos < digits.length()-1 && digits[pos] == 0) ++pos;
        int64_t segmentLength = std::min(uint64_t(254), digits.length()-pos);
        char segment[254];
        for(int64_t i=0;i<segmentLength;i++) segment[i]=digits[pos+i];
        appendNumericSegmentCEs(segment, segmentLength, errorCode);
        pos += segmentLength;
    } while(U_SUCCESS(errorCode) && pos < digits.length());'''+s[end:]
        output='externaliterator' if stem=='collationiterator' else 'externalcompare'
        (root/f'{output}.{ext}').write_text(s)
tbl=(src/'unicode/tblcoll.h').read_text().replace('friend class CollationElementIterator;','friend class CollationElementIterator;\n    friend class MacEaseDiskComparator;')
(root/'include/unicode').mkdir(parents=True,exist_ok=True)
(root/'include/unicode/tblcoll.h').write_text(tbl)
