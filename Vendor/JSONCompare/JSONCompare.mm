#include "DiskStorage.hpp"
#include "collationdata.h"
#include "collationsettings.h"
#include "externalcompare.h"
#include "externaliterator.h"
#import <Foundation/Foundation.h>
#include <memory>
#include <unicode/tblcoll.h>
#include <unicode/uchar.h>
#include <unicode/ucol.h>
#include <unicode/unorm2.h>

U_NAMESPACE_BEGIN
class DiskIterator final : public ExternalCollationIterator {
    const DiskUTF16 &text;
    uint64_t start;
    uint64_t position;
    uint32_t otherHalf = 0;

  public:
    DiskIterator(const CollationData *d, const DiskUTF16 &t, uint64_t s = 0, uint64_t skip = 0)
        : ExternalCollationIterator(d, true), text(t), start(s), position(s + skip) {}
    void resetToOffset(int64_t offset) override {
        position = start + offset;
        otherHalf = 0;
        reset();
    }
    int64_t getOffset() const override {
        return position - start;
    }
    UChar32 nextCodePoint(UErrorCode &) override {
        if (position >= text.length())
            return U_SENTINEL;
        UChar32 c = text[position++];
        if (U16_IS_LEAD(c) && position < text.length() && U16_IS_TRAIL(text[position]))
            return U16_GET_SUPPLEMENTARY(c, text[position++]);
        return c;
    }
    UChar32 previousCodePoint(UErrorCode &) override {
        if (position == start)
            return U_SENTINEL;
        UChar32 c = text[--position];
        if (U16_IS_TRAIL(c) && position > start && U16_IS_LEAD(text[position - 1]))
            return U16_GET_SUPPLEMENTARY(text[--position], c);
        return c;
    }
    void forwardNumCodePoints(int64_t count, UErrorCode &status) override {
        while (count-- > 0 && nextCodePoint(status) >= 0) {
        }
    }
    void backwardNumCodePoints(int64_t count, UErrorCode &status) override {
        while (count-- > 0 && previousCodePoint(status) >= 0) {
        }
    }
    int32_t oldCE(UErrorCode &status) {
        if (otherHalf) {
            uint32_t result = otherHalf;
            otherHalf = 0;
            return result;
        }
        clearCEsIfNoneRemaining();
        int64_t ce = nextCE(status);
        if (ce == Collation::NO_CE)
            return -1;
        uint32_t p = ce >> 32, low = ce;
        uint32_t first = (p & 0xffff0000) | ((low >> 16) & 0xff00) | ((low >> 8) & 0xff);
        uint32_t second = (p << 16) | ((low >> 8) & 0xff00) | (low & 0x3f);
        if (second)
            otherHalf = second | 0xc0;
        return first;
    }
};
class MacEaseDiskComparator {
    const RuleBasedCollator &collator;
    static int sign(int64_t n) {
        return (n > 0) - (n < 0);
    }
    static void normalized(const DiskUTF16 &source, uint64_t start, DiskUTF16 &output) {
        std::array<std::unique_ptr<DiskUTF16>, 256> buckets;
        auto flush = [&]() {
            for (auto &bucket : buckets) {
                if (bucket) {
                    for (uint64_t k = 0; k < bucket->length(); k++)
                        output.append((*bucket)[k]);
                    bucket->remove();
                }
            }
        };
        UErrorCode status = U_ZERO_ERROR;
        const UNormalizer2 *nfd = unorm2_getNFDInstance(&status);
        if (U_FAILURE(status))
            throw DiskFailure(ME_JSON_COMPARE_ICU, "open normalizer", 0, status);
        char16_t mapping[256];
        for (uint64_t pos = start; pos < source.length();) {
            UChar32 c = source[pos++];
            if (U16_IS_LEAD(c) && pos < source.length() && U16_IS_TRAIL(source[pos]))
                c = U16_GET_SUPPLEMENTARY(c, source[pos++]);
            int32_t length = unorm2_getDecomposition(nfd, c, mapping, 256, &status);
            if (U_FAILURE(status))
                throw DiskFailure(ME_JSON_COMPARE_ICU, "scalar decomposition", 0, status);
            auto put = [&](UChar32 scalar) {
                uint8_t cls = u_getCombiningClass(scalar);
                if (cls == 0) {
                    flush();
                    output.append(scalar);
                } else {
                    if (!buckets[cls])
                        buckets[cls] = std::make_unique<DiskUTF16>();
                    buckets[cls]->append(scalar);
                }
            };
            if (length < 0)
                put(c);
            else {
                for (int32_t i = 0; i < length;) {
                    UChar32 scalar;
                    U16_NEXT(mapping, i, length, scalar);
                    put(scalar);
                }
            }
        }
        flush();
    }
    int pass(const DiskUTF16 &a, uint64_t ap, const DiskUTF16 &b, uint64_t bp,
             const CollationSettings &settings, UErrorCode &status) const {
        uint64_t prefix = 0, al = a.length() - ap, bl = b.length() - bp;
        while (prefix < al && prefix < bl && a[ap + prefix] == b[bp + prefix])
            ++prefix;
        if (prefix == al && prefix == bl)
            return 0;
        if (prefix > 0 && ((prefix < al && collator.data->isUnsafeBackward(a[ap + prefix], true)) ||
                           (prefix < bl && collator.data->isUnsafeBackward(b[bp + prefix], true)))) {
            while (--prefix > 0 && collator.data->isUnsafeBackward(a[ap + prefix], true)) {
            }
        }
        DiskIterator x(collator.data, a, ap, prefix), y(collator.data, b, bp, prefix);
        return ExternalCollationCompare::compareUpToQuaternary(x, y, settings, status);
    }
    int specials(const DiskUTF16 &a, uint64_t ap, const DiskUTF16 &b, uint64_t bp) const {
        DiskIterator x(collator.data, a, ap), y(collator.data, b, bp);
        UErrorCode status = U_ZERO_ERROR;
        int64_t lastX = 0, lastY = 0;
        int composition = 0;
        while (U_SUCCESS(status)) {
            int32_t xc = x.oldCE(status), yc = y.oldCE(status);
            if (xc == -1 || yc == -1)
                break;
            int64_t xp = x.getOffset(), yp = y.getOffset();
            if ((xc & 0xffffff00) == (yc & 0xffffff00)) {
                if (xc & 0xffff0000) {
                    int xt = xc & 255, yt = yc & 255;
                    if (xt >= 0x8f && xt <= 0x97)
                        xt -= 0x8a;
                    if (yt >= 0x8f && yt <= 0x97)
                        yt -= 0x8a;
                    if (xt != yt)
                        return sign(xt - yt);
                } else if ((xc & 0xff00) && !composition)
                    composition = -sign((xp - lastX) - (yp - lastY));
            }
            lastX = xp;
            lastY = yp;
        }
        if (U_FAILURE(status))
            throw DiskFailure(ME_JSON_COMPARE_ICU, "special CEs", 0, status);
        return composition;
    }

  public:
    explicit MacEaseDiskComparator(const RuleBasedCollator &c) : collator(c) {}
    int compare(const DiskUTF16 &a, uint64_t ap, const DiskUTF16 &b, uint64_t bp) const {
        CollationSettings settings(*collator.settings);
        settings.options &= ~(CollationSettings::CASE_LEVEL | CollationSettings::CHECK_FCD);
        UErrorCode status = U_ZERO_ERROR;
        settings.setStrength(UCOL_PRIMARY, settings.options, status);
        {
            int result = pass(a, ap, b, bp, settings, status);
            if (U_FAILURE(status))
                throw DiskFailure(ME_JSON_COMPARE_ICU, "primary CEs", 0, status);
            if (result)
                return sign(result);
        }
        DiskUTF16 an, bn;
        normalized(a, ap, an);
        normalized(b, bp, bn);
        settings.setStrength(UCOL_SECONDARY, settings.options, status);
        settings.options |= CollationSettings::CASE_LEVEL;
        {
            int result = pass(an, 0, bn, 0, settings, status);
            if (U_FAILURE(status))
                throw DiskFailure(ME_JSON_COMPARE_ICU, "secondary CEs", 0, status);
            if (result)
                return sign(result);
        }
        return specials(a, ap, b, bp);
    }
};
U_NAMESPACE_END
using namespace icu;
static bool digit(char16_t c) {
    return c >= '0' && c <= '9';
}
static uint64_t back(const DiskUTF16 &v, uint64_t p) {
    NSCharacterSet *nonBase = [NSCharacterSet nonBaseCharacterSet];
    NSCharacterSet *punctuation = [NSCharacterSet punctuationCharacterSet];
    if (p)
        --p;
    while (p) {
        UChar32 c = v[p];
        if (U16_IS_TRAIL(c) && U16_IS_LEAD(v[p - 1])) {
            // Foundation retains the trailing-surrogate boundary.
            break;
        } else {
            if ((c >= 0x2e80 && c < 0xac00) ||
                (![nonBase longCharacterIsMember:c] && ![punctuation longCharacterIsMember:c]))
                break;
            --p;
        }
    }
    return p;
}
static int compatibility(const MacEaseDiskComparator &c, const DiskUTF16 &x, const DiskUTF16 &y) {
    uint64_t i = 0, j = 0;
    while (i < x.length() && j < y.length()) {
        if (digit(x[i]) && digit(y[j])) {
            uint64_t n = 0, m = 0;
            do {
                n = n * 10 + x[i++] - '0';
            } while (i < x.length() && digit(x[i]));
            do {
                m = m * 10 + y[j++] - '0';
            } while (j < y.length() && digit(y[j]));
            if (n != m)
                return n < m ? -1 : 1;
        } else if (x[i] != y[j])
            return c.compare(x, back(x, i), y, back(y, j));
        else {
            ++i;
            ++j;
        }
    }
    return (i < x.length()) - (j < y.length());
}

#include <unicode/udata.h>
extern "C" const char macease_legacy_dat[];

static void initializeTables() {
    static const bool initialized = [] {
        NSLocale *locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        NSComparisonResult sidetic = [@"\U00010940" compare:@"中"
                                                    options:NSLiteralSearch | NSNumericSearch
                                                      range:NSMakeRange(0, 2)
                                                     locale:locale];
        NSComparisonResult symbol = [@"\U0001faea" compare:@"a"
                                                   options:NSLiteralSearch | NSNumericSearch
                                                     range:NSMakeRange(0, 2)
                                                    locale:locale];
        if (sidetic == NSOrderedDescending && symbol == NSOrderedDescending) {
            UErrorCode status = U_ZERO_ERROR;
            udata_setCommonData(macease_legacy_dat, &status);
            if (U_FAILURE(status))
                throw DiskFailure(ME_JSON_COMPARE_ICU, "select legacy data", 0, status);
        } else if (sidetic != NSOrderedAscending || symbol != NSOrderedAscending) {
            throw DiskFailure(ME_JSON_COMPARE_ICU, "unrecognized Foundation collation generation", 0,
                              U_UNSUPPORTED_ERROR);
        }
        return true;
    }();
    (void)initialized;
}

static void validateSpan(MEJSONUTF16Span span) {
    if (span.byteLength % 2)
        throw DiskFailure(ME_JSON_COMPARE_INVALID_SPAN, "unaligned UTF16 length");
    off_t end = diskOffset(span.byteLength, 1, span.byteOffset);
    struct stat details;
    if (fstat(span.descriptor, &details) != 0)
        throw DiskFailure(ME_JSON_COMPARE_IO, "stat input", errno);
    if (!S_ISREG(details.st_mode) || details.st_size < end)
        throw DiskFailure(ME_JSON_COMPARE_INVALID_SPAN, "input span outside file");
}
MEJSONCompareResult MEJSONCompareFoldedUTF16(MEJSONUTF16Span left, MEJSONUTF16Span right,
                                             int scratchDirectory, MEJSONCancelled cancelled, void *context) {
    @autoreleasepool {
        DiskOperation operation{scratchDirectory, cancelled, context};
        struct RestoreOperation {
            DiskOperation *previous;
            ~RestoreOperation() {
                diskOperation = previous;
            }
        } restore{diskOperation};
        diskOperation = &operation;
        try {
            operation.poll();
            validateSpan(left);
            validateSpan(right);
            struct stat directory;
            if (fstat(scratchDirectory, &directory) != 0)
                throw DiskFailure(ME_JSON_COMPARE_IO, "stat scratch directory", errno);
            if (!S_ISDIR(directory.st_mode))
                throw DiskFailure(ME_JSON_COMPARE_INVALID_SPAN, "scratch directory required");
            initializeTables();
            UErrorCode status = U_ZERO_ERROR;
            std::unique_ptr<UCollator, decltype(&ucol_close)> collator(ucol_open("en_US_POSIX", &status),
                                                                       &ucol_close);
            if (U_FAILURE(status))
                throw DiskFailure(ME_JSON_COMPARE_ICU, "open collator", 0, status);
            ucol_setAttribute(collator.get(), UCOL_NUMERIC_COLLATION, UCOL_ON, &status);
            ucol_setAttribute(collator.get(), UCOL_ALTERNATE_HANDLING, UCOL_NON_IGNORABLE, &status);
            if (U_FAILURE(status))
                throw DiskFailure(ME_JSON_COMPARE_ICU, "configure collator", 0, status);
            MacEaseDiskComparator comparator(*RuleBasedCollator::rbcFromUCollator(collator.get()));
            DiskUTF16 x(left), y(right);
            int ordering = compatibility(comparator, x, y);
            operation.poll();
            return {ME_JSON_COMPARE_OK, ordering, 0, 0};
        } catch (const DiskFailure &failure) {
            return {failure.status, 0, failure.systemError, failure.icuError};
        } catch (const std::bad_alloc &) {
            return {ME_JSON_COMPARE_MEMORY, 0, 0, 0};
        } catch (const std::exception &) {
            return {ME_JSON_COMPARE_INTERNAL, 0, 0, 0};
        }
    }
}
