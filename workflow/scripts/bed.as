table gene_conversion
"Windows with evidence of gene conversion"
(
string  chrom;		"Chromosome for site 1"
uint    chromStart;	"Start for site 1"
uint    chromEnd;	"End for site 1"
string  name;		"Name with mismatch delta"
uint    score;		"NA"
char[1]  strand;		"strand NA"
uint    thickStart;	"End"
uint    thickEnd;	"Start"
uint  reserved;		"RGB color, blue = acceptor, orange = donor"
string  Status;		"Is this location the donor or acceptor site"
string  ChromTwo;		"Chromosome for site 2"
uint    StartTwo;	"Start for site 2"
uint    EndTwo;	"End for site 2"
uint    mismatches;		"mismatches at original alignment"
uint    donorMismatches;		"mismatches at donor alignment"
float    perID_by_all;		"Percent identity of alignment at original alignment location"
float    donor_perID_by_all;		"Percent identity of alignment at donor location"
string  Source;		"Source location on the assembly"
)