//Written in the D programming language
/*
    Implementation of a concept "NFA in a word" which is
    bit-parallel impementation of regex where each bit represents
    a state in an NFA. Execution is Thompson-style achieved via bit tricks.

    There is a great number of limitations inlcuding not tracking any state (captures)
    and not supporting even basic assertions such as ^, $  or \b.
*/
module std.regex.internal.bitnfa;

package(std.regex):

import std.regex.internal.ir;

debug(std_regex_bitnfa) import std.stdio;
import std.algorithm;


struct HashTab
{
pure:
    @disable this(this);

    uint opIndex()(uint key) const
    {
        auto p = locate(key, table);
        assert(p.occupied);
        return p.value;
    }

    bool opBinaryRight(string op:"in")(uint key) const
    {
        auto p = locate(key, table);
        return p.occupied;
    }

    void opIndexAssign(uint value, uint key)
    {
        if (table.length == 0) grow();
        auto p = locate(key, table);
        if (!p.occupied)
        {
            items++;
            if (4 * items >= table.length * 3)
            {
                grow();
                p = locate(key, table);
            }
            p.key_ = key;
            p.setOccupied();
        }
        p.value = value;
    }

    auto keys() const
    {
        import std.array : appender;
        auto app = appender!(uint[])();
        foreach (i, v; table)
        {
            if (v.occupied)
                app.put(v.key);
        }
        return app.data;
    }

    auto values() const
    {
        import std.array : appender;
        auto app = appender!(uint[])();
        foreach (i, v; table)
        {
            if (v.occupied)
                app.put(v.value);
        }
        return app.data;
    }

private:
    static uint hashOf()(uint val)
    {
        return (val >> 20) ^ (val>>8) ^ val;
    }

    struct Node
    {
    pure:
        uint key_;
        uint value;
        @property uint key()() const { return key_ & 0x7fff_ffff; }
        @property bool occupied()() const { return (key_ & 0x8000_0000) != 0; }
        void setOccupied(){ key_ |= 0x8000_0000; }
    }
    Node[] table;
    size_t items;

    static N* locate(N)(uint key, N[] table)
    {
        size_t slot = hashOf(key) & (table.length-1);
        while (table[slot].occupied)
        {
            if (table[slot].key == key)
                break;
            slot += 1;
            if (slot == table.length)
                slot = 0;
        }
        return table.ptr + slot;
    }

    void grow()
    {
        Node[] newTable = new Node[table.length ? table.length*2 : 4];
        foreach (i, v; table)
        {
            if (v.occupied)
            {
                auto p = locate(v.key, newTable);
                *p = v;
            }
        }
        table = newTable;
    }
}

unittest
{
    HashTab tab;
    tab[3] = 1;
    tab[7] = 2;
    tab[11] = 3;
    assert(tab[3] == 1);
    assert(tab[7] == 2);
    assert(tab[11] == 3);
}


// Specialized 2-level trie of uint masks for BitNfa.
// Uses the concept of CoW: a page gets modified in place
// if the block's ref-count is 1, else a newblock is allocated
// and ref count is decreased
struct UIntTrie2
{
pure:
    ushort[] index;                       // pages --> blocks
    ushort[] refCounts;                   // ref counts for each block
    uint[]   hashes;                      // hashes of blocks
    uint[]   blocks;                      // linear array with blocks
    uint[]   scratch;                     // temporary block
    enum     blockBits = 8;               // size of block in bits
    enum     blockSize = 1<<blockBits;    // size of block


    static uint hash(uint[] data)
    {
        uint h = 5183;
        foreach (v; data)
        {
            h = 31*h + v;
        }
        return h;
    }

    static UIntTrie2 opCall()
    {
        UIntTrie2 ut;
        ut.index.length = 2<<13;
        ut.blocks = new uint[blockSize];
        ut.blocks[] = uint.max; // all ones
        ut.scratch = new uint[blockSize];
        ut.refCounts = new ushort[1];
        ut.refCounts[0] = 2<<13;
        ut.hashes = new uint[1];
        ut.hashes[0] = hash(ut.blocks);
        return ut;
    }

    uint opIndex(dchar ch) const
    {
        immutable blk = index[ch>>blockBits];
        return blocks.ptr[blk*blockSize + (ch & (blockSize-1))];
    }

    void setPageRange(string op)(uint val, uint low, uint high)
    {
        immutable blk = index[low>>blockBits];
        if (refCounts[blk] == 1) // modify in-place
        {
            immutable lowIdx = blk*blockSize + (low & (blockSize-1));
            immutable highIdx = high - low + lowIdx;
            mixin("blocks[lowIdx..highIdx] "~op~"= val;");
        }
        else
        {
            // create a new page
            refCounts[blk]--;
            immutable lowIdx = low & (blockSize-1);
            immutable highIdx = high - low + lowIdx;
            scratch[] = blocks[blk*blockSize..(blk+1)*blockSize];
            mixin("scratch[lowIdx..highIdx] "~op~"= val;");
            uint h = hash(scratch);
            bool found = false;
            foreach (i,x; hashes)
            {
                if (x != h) continue;
                if (scratch[] == blocks[i*blockSize .. (i+1)*blockSize])
                {
                    // re-route to existing page
                    index[low>>blockBits] = cast(ushort)i;
                    refCounts[i]++; // inc refs
                    found = true;
                    break;
                }
            }
            if (!found)
            {
                index[low>>blockBits] = cast(ushort)hashes.length;
                blocks ~= scratch[];
                refCounts ~= 1;
                hashes ~= h;
            }
        }
    }

    void opIndexOpAssign(string op)(uint val, dchar ch)
    {
        setPageRange!op(val, ch, ch+1);
    }

    void opSliceOpAssign(string op)(uint val, uint start, uint end)
    {
        uint startBlk  = start >> blockBits;
        uint endBlk = end >> blockBits;
        uint first = min(startBlk*blockSize+blockSize, end);
        setPageRange!op(val, start, first);
        foreach (blk; startBlk..endBlk)
            setPageRange!op(val, blk*blockSize, (blk+1)*blockSize);
        if (first != end)
        {
            setPageRange!op(val, endBlk*blockSize, end);
        }
    }
}

unittest
{
    UIntTrie2 trie = UIntTrie2();
    trie['d'] &= 3;
    assert(trie['d'] == 3);
    trie['\u0280'] &= 1;
    assert(trie['\u0280'] == 1);
    import std.uni;
    UIntTrie2 trie2 = UIntTrie2();
    auto letters = unicode("L");
    foreach (r; letters.byInterval)
        trie2[r.a..r.b] &= 1;
    foreach (ch; letters.byCodepoint)
        assert(trie2[ch] == 1);
    auto space = unicode("WhiteSpace");
    auto trie3 = UIntTrie2();
    foreach (r; space.byInterval)
        trie3[r.a..r.b] &= 2;
    foreach (ch; space.byCodepoint)
        assert(trie3[ch] == 2);
}

// Since there is no way to mark a starting position
// we need 2 instances of BitNfa: one to find the end, and the other
// to run backwards to find the start.
struct BitNfa
{
pure:
    uint[128]   asciiTab;         // state mask for ascii characters
    UIntTrie2   uniTab;           // state mask for unicode characters
    HashTab     controlFlow;      // maps each bit pattern to resulting jumps pattern
    uint        controlFlowMask;  // masks all control flow bits
    uint        finalMask;        // marks final states terminating the NFA
    uint        length;            // if this engine is empty

    @property bool empty() const { return length == 0; }

    void combineControlFlow()
    {
        uint[] keys = controlFlow.keys;
        uint[] values = controlFlow.values;
        auto selection = new bool[keys.length];
        bool nextChoice()
        {
            uint i;
            for (i=0;i<selection.length; i++)
            {
                selection[i] ^= true;
                if (selection[i])
                    break;
            }
            return i != selection.length;
        }
        // first prepare full mask
        foreach (k; keys) controlFlowMask |= k;
        // next set all combinations in cf
        while (nextChoice())
        {
            uint kmask = 0, vmask = 0;
            foreach (i,v; selection)
                if (v)
                {
                    kmask |= keys[i];
                    vmask |= values[i];
                }
            controlFlow[kmask] = vmask;
        }
    }

    uint[] collectControlFlow(Bytecode[] ir, uint i)
    {
        uint[] result;
        bool[] visited = new bool[ir.length];
        Stack!uint paths;
        paths.push(i);
        while (!paths.empty())
        {
            uint j = paths.pop();
            if (visited[j]) continue;
            visited[j] = true;
            switch (ir[j].code) with(IR)
            {
            case OrStart:
                j += IRL!OrStart;
                assert(ir[j].code == Option);
                while (ir[j].code == Option)
                {
                    //import std.stdio;
                    //writefln("> %d %s", j, ir[j].mnemonic);
                    paths.push(j+IRL!Option);
                    //writefln(">> %d", j+IRL!Option);
                    j = j + ir[j].data + IRL!Option;
                }
                break;
            case GotoEndOr:
                paths.push(j+IRL!GotoEndOr+ir[j].data);
                break;
            case OrEnd, Wordboundary, Notwordboundary, Bof, Bol, Eol, Eof, Nop, GroupStart, GroupEnd:
                paths.push(j+ir[j].length);
                break;
            case LookaheadStart, NeglookaheadStart, LookbehindStart,
                NeglookbehindStart:
                paths.push(j + IRL!LookaheadStart + ir[j].data + IRL!LookaheadEnd);
                break;
            case InfiniteStart, InfiniteQStart:
                paths.push(j+IRL!InfiniteStart);
                paths.push(j+IRL!InfiniteStart+ir[j].data+IRL!InfiniteEnd);
                break;
            case InfiniteBloomStart:
                paths.push(j+IRL!InfiniteStart);
                paths.push(j+IRL!InfiniteBloomStart+ir[j].data+IRL!InfiniteBloomEnd);
                break;
            case InfiniteEnd, InfiniteQEnd:
                paths.push(j-ir[j].data);
                paths.push(j+IRL!InfiniteEnd);
                break;
            case InfiniteBloomEnd:
                paths.push(j-ir[j].data);
                paths.push(j+IRL!InfiniteBloomEnd);
                break;
            default:
                result ~= j;
            }
        }
        return result;
    }

    this(Char)(auto ref Regex!Char re)
    {
        asciiTab[] = uint.max; // all ones
        uniTab = UIntTrie2();
        controlFlow[0] = 0;
        // pc -> bit number
        uint[] bitMapping = new uint[re.ir.length];
        uint bitCount = 0, nesting=0, lastNonnested=0;
        with(re)
outer:  for (uint i=0; i<ir.length; i += ir[i].length) with(IR)
        {
            if (nesting == 0) lastNonnested = i;
            if (ir[i].isStart) nesting++;
            if (ir[i].isEnd) nesting--;
            switch (ir[i].code)
            {
            case Option, OrEnd, Nop, Bof, Bol,
            GroupStart, GroupEnd,
            Eol, Eof, Wordboundary, Notwordboundary:
                bitMapping[i] = bitCount;
                break;
            // skipover complex assertions
            case LookaheadStart, NeglookaheadStart, LookbehindStart,
                NeglookbehindStart:
                bitMapping[i] = bitCount;
                nesting--;
                i += IRL!LookbehindStart + ir[i].data; // IRL end gets skiped by 'for'
                break;
            // unsupported instructions
            case RepeatStart, RepeatQStart, Backref:
                bitMapping[i] = bitCount;
                break outer;
            case OrChar:
                uint s = ir[i].sequence;
                for (uint j=i; j<i+s; j++)
                    bitMapping[j] = bitCount;
                i += (s-1)*IRL!OrChar;
                bitCount++;
                if (bitCount == 32)
                    break outer;
                break;
            default:
                bitMapping[i] = bitCount++;
                if (bitCount == 32)
                    break outer;
            }
        }
        debug(std_regex_bitnfa) __ctfe || writeln("LEN:", lastNonnested);
        // the total processable length
        finalMask |= 1u<<bitMapping[lastNonnested];
        length = lastNonnested;
        with(re)
        for (uint i=0; i<length; i += ir[i].length)
        {
            switch (ir[i].code) with (IR)
            {
            case OrStart,GotoEndOr, InfiniteStart,
            InfiniteQStart,InfiniteBloomStart,
            InfiniteBloomEnd, InfiniteEnd, InfiniteQEnd:
                // collect stops across all paths
                auto rets = collectControlFlow(ir, i);
                uint mask = 0;
                debug(std_regex_bitnfa) __ctfe || writeln(rets);
                foreach (pc; rets) mask |= 1u<<bitMapping[pc];
                // map this individual c-f to all possible stops
                controlFlow[1u<<bitMapping[i]] = mask;
                break;
            case Option, OrEnd, Nop, Bol, Bof,
                GroupStart, GroupEnd,
                Eol, Eof, Wordboundary, Notwordboundary:
                break;
            case LookaheadStart, NeglookaheadStart, LookbehindStart,
                NeglookbehindStart:
                i += IRL!LookaheadStart + ir[i].data;
                break;
            case End:
                finalMask |= 1u<<bitMapping[i];
                break;
            case Any:
                uint mask = 1u<<bitMapping[i];
                asciiTab[0..0x80] &= ~mask;
                uniTab[0..0x11_0000] &= ~mask;
                break;
            case Char:
                uint mask = 1u<<bitMapping[i];
                auto ch = ir[i].data;
                //import std.stdio;
                //writefln("Char %c - %b", cast(dchar)ch, mask);
                if (ch < 0x80)
                    asciiTab[ch] &= ~mask;
                else
                    uniTab[ch] &= ~mask;
                break;
            case OrChar:
                uint s = ir[i].sequence;
                for (size_t j=i; j<i+s; j++)
                {
                    uint mask = 1u<<bitMapping[i];
                    auto ch = ir[j].data;
                    //import std.stdio;
                    //writefln("OrChar %c - %b", cast(dchar)ch, mask);
                    if (ch < 0x80)
                        asciiTab[ch] &= ~mask;
                    else
                        uniTab[ch] &= ~mask;
                }
                i += s-1;
                break;
            case CodepointSet, Trie:
                auto cset = charsets[ir[i].data];
                uint mask = 1u<<bitMapping[i];
                foreach (ival; cset)
                {
                    if (ival.b < 0x80)
                        asciiTab[ival.a..ival.b] &= ~mask;
                    else
                    {
                        if (ival.a < 0x80)
                            asciiTab[ival.a..0x80] &= ~mask;
                        uniTab[ival.a..ival.b] &= ~mask;
                    }
                }
                break;
            default:
                assert(0, "Unexpected instruction in BitNFA: "~ir[i].mnemonic);
            }
        }
        length += re.ir[lastNonnested].length;
        combineControlFlow();
        if (0x1 & finalMask)
        {
            length = 0;
        }
        else if (0x1 in controlFlow)
        {
            if (controlFlow[0x01] & finalMask)
                length = 0; // set zero-width as empty
        }
    }

    bool search(Input)(ref Input r) const
    {
        dchar ch;
        size_t idx;
        uint word = ~0u;
        for (;;)
        {
            word <<= 1; // shift - create a state
            // cfMask has 1 for each control-flow op
            uint cflow = ~word  & controlFlowMask;
            word = word | controlFlowMask; // kill cflow
            word &= ~controlFlow[cflow]; // map normal ops
            debug(std_regex_bitnfa) __ctfe || writefln("%b %b %b %b", word, finalMask, cflow, controlFlowMask);
            if ((word & finalMask) != finalMask)
            {
                return true;
            }
            if (!r.nextChar(ch, idx))
                break;
            // mask away failing states
            if (ch < 0x80)
                word |= asciiTab[ch];
            else
                word |= uniTab[ch];
        }
        return false;
    }

    bool match(Input)(ref Input r) const
    {
        dchar ch;
        size_t idx;
        uint word = ~1u;
        size_t mIdx = 0;
        bool matched = false;
        auto save = r._index;
        for (;;)
        {
            // cfMask has 1 for each control-flow op
            uint cflow = ~word  & controlFlowMask;
            word = word | controlFlowMask; // kill cflow
            word &= ~controlFlow[cflow]; // map normal ops
            debug(std_regex_bitnfa) __ctfe || writefln("%b %b %b %b", word, finalMask, cflow, controlFlowMask);
            if ((word & finalMask) != finalMask)
            {
                // keep running to see if there is longer match
                matched = true;
                mIdx = r._index;
            }
            else if (word == ~0u) // no active states
                break;
            if (!r.nextChar(ch, idx))
                break;
            // mask away failing states
            if (ch < 0x80)
                word |= asciiTab[ch];
            else
                word |= uniTab[ch];
            // shift and
            word = (word<<1) | 1;

        }
        if (matched)
            r.reset(mIdx);
        else
            r.reset(save);
        return matched;
    }
}

auto reverseBitNfa(Char)(auto ref Regex!Char re, uint length) pure
{
    auto re2 = re;
    re2.ir = re2.ir.dup;
    uint len = length - 1;
    reverseBytecode(re2.ir[0..len]);
    // check for the case of multiple patterns as one alternation
    if (len == re2.ir.length-IRL!(IR.End))
    {
        debug(std_regex_bitnfa) __ctfe || writeln("Reverse!");
        with(IR) with(re2) if (ir[0].code == OrStart)
        {
            size_t pc = IRL!OrStart;
            while (ir[pc].code == Option)
            {
                size_t size = ir[pc].data;
                size_t j = pc + IRL!Option;
                if (ir[j].code == End)
                {
                    auto save = ir[j];
                    foreach (k; j+1..j+size)
                        ir[k-1] = ir[k];
                    ir[j+size-1] = save;
                }
                pc = j + ir[pc].data;
            }
        }
    }
    debug(std_regex_bitnfa) __ctfe || re2.print();
    return BitNfa(re2);
}

final class BitMatcher(Char) : Kickstart!(Char)
    if (is(Char : dchar))
{
@trusted:
    BitNfa forward, backward;

    pure this()(auto ref Regex!Char re)
    {
        forward = BitNfa(re);
        // keep the end where it belongs
        if (!forward.empty)
            backward = reverseBitNfa(re, forward.length);
    }

    final bool search(ref Input!Char r) const
    {
        auto save = r._index;
        bool res = forward.search(r);
        if (res)
        {
            auto back = r.loopBack(r._index);
            auto t = backward.match(back);
            assert(t);
            if (back._index < save)
                r.reset(save);
            else
                r.reset(back._index);
        }
        return res;
    }

    final bool match(ref Input!Char r) const
    {
        auto save = r._index;
        bool res = forward.match(r);
        r.reset(save);
        return res;
    }

    final @property bool empty() pure const{ return forward.empty; }
}

version(unittest)
{
    template check(alias make)
    {
        private void check(T)(string input, T re, size_t idx=uint.max, int line=__LINE__)
        {
            import std.regex, std.conv;
            import std.stdio;
            auto rex = regex(re, "s");
            auto m = make(rex);
            auto s = Input!char(input);
            assert(m.search(s), text("Failed @", line, " ", input, " with ", re));
            assert(s._index == idx || (idx ==uint.max && s._index == input.length),
                text("Failed @", line, " index=", s._index));
        }
    }

    template checkFail(alias make)
    {
        private void checkFail(T)(string input, T re, size_t idx=uint.max, int line=__LINE__)
        {
            import std.regex, std.conv;
            import std.stdio;
            auto rex = regex(re, "s");
            auto m = make(rex);
            auto s = Input!char(input);
            assert(!m.search(s), text("Should have failed @", line, " " , input, " with ", re));
            assert(s._index == idx || (idx ==uint.max && s._index == input.length));
        }
    }

    private void checkEmpty(T)(T re)
    {
        import std.regex, std.conv;
        import std.stdio;
        auto rex = regex(re);
        auto m = BitNfa(rex);
        assert(m.empty, "Should be empty "~to!string(re));
    }

    alias checkBit = check!BitNfa;
    alias checkBitFail = checkFail!BitNfa;
    auto makeMatcher(Char)(Regex!Char regex){ return new BitMatcher!(Char)(regex); }
    alias checkM = check!makeMatcher;
    alias checkMFail = checkFail!makeMatcher;
}

unittest
{
    "xabcd".checkBit("abc", 4);
    "xabbbcdyy".checkBit("a[b-c]*c", 6);
    "abc1".checkBit("([a-zA-Z_0-9]*)1");
    "(a|b)*".checkEmpty;
    "abbabc".checkBit("(a|b)*c");
    "abd".checkBitFail("abc");
    // check truncation
    "0123456789_0123456789_0123456789_012"
        .checkBit("0123456789_0123456789_0123456789_0123456789", 31);
    "0123456789_0123456789_0123456789_012"
        .checkBit("0123456789(0123456789_0123456789_0123456789_0123456789|01234)",10);
    "0123456789_0123456789_0123456789_012"
        .checkBit("0123456789_0123456789_012345678[890]", 31);
    // assertions ignored
    "0abc1".checkBit("(?<![0-9])[a-c]+$", 2);
    // stop on repetition
    "abcdef1".checkBit("a[a-z]{5}", 1);
    "ads@email.com".checkBit(`\S+@\S+`,5);
    "abc@email.com".checkBit(`\S+@\S?1`, 4);
    "1".checkBit(r"\d+",1);
    "()*".checkEmpty;
    "^".checkEmpty;
    "abc".checkBit(`\w[bc]`, 2);
}

unittest
{
    "xxabcy".checkM("abc", 2);
    "пень".checkM("пен.", 0);
    "_10bcy".checkM([`\d+`, `[a-z]+`, `\*`], 1);
    "1/03/12 - 3/03/12".checkM([r"\d+/\d+/\d+"],0);
    "abcя@email.com".checkM(`\S+@\S?1`, 0);
    "Strap a rocket engine on a chicken.".checkM("[ra]", 2);
    "abcd".checkM("ab|cd", 0);
    "abcd".checkM("(a|b|c)*(?=x)d", 0);
}
