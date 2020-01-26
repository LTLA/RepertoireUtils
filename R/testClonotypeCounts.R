#' Test for differences in clonotype diversity
#'
#' Test for significant differences in the diversity of clonotypes between groups.
#'
#' @inheritParams summarizeClonotypeCounts
#' @param iterations Positive integer scalar indicating the number of permutation iterations to use for testing.
#' @param adj.method String specifying the multiple testing correction method to use across pairwise comparisons.
#' @param BPPARAM A \linkS4class{BiocParallelParam} object specifying how parallelization should be performed.
#'
#' @return A \linkS4class{List} of numeric matrices containing p-values for pairwise comparisons of diversity between groups.
#' Each matrix is lower-triangular as the tests do not consider directionality.
#'
#' @details
#' This function computes permutation p-values to test for significant differences in the diversity values of different groups,
#' as computed using \code{\link{summarizeClonotypeCounts}}.
#' The aim is to help to whether one group is significantly more or less diverse,
#' providing evidence for differences in the rate of clonal expansion between clusters or conditions.
#'
#' Under the null hypothesis, two groups are derived from a pool of cells with the same clonotype composition.
#' We randomly sample without replacement to obtain two permuted groups that match the size of the original groups,
#' recompute the diversity indices in this permuted data 
#' and calculate the absolute difference of the diversity indices between groups.
#' Our permutation p-value is computed by comparing the observed absolute difference with the null distribution,
#' using the Phipson and Smyth (2010) approach to avoid p-values of zero.
#'
#' We repeat this process for each diversity index, e.g., Gini index, Hill numbers.
#' This yields a matrix of p-values per index where each row and column represents a group.
#' Within each index, we apply a multiple testing correction over all pairwise comparisons between groups.
#'
#' Again, it is a good idea to downsample to ensure that all groups are of the same size.
#' Otherwise, the permutation test will not be symmetric;
#' it will only ever be significant if the larger group has the larger index.
#'
#' @author Aaron Lun
#'
#' @examples
#' df <- data.frame(
#'     cell.id=sample(LETTERS, 30, replace=TRUE),
#'     clonotype=sample(paste0("clonotype_", 1:5), 30, replace=TRUE)
#' )
#' 
#' y <- splitToCells(df, field="cell.id")
#' out <- countCellsPerClonotype(y, "clonotype",
#'    group=sample(3, length(y), replace=TRUE))
#'
#' test.out <- testClonotypeCountsPairwise(out)
#' test.out$gini
#'
#' @seealso
#' \code{\link{summarizeClonotypeCounts}}, to compute diversity indices.
#'
#' @export
#' @importFrom stats p.adjust
#' @importFrom BiocParallel SerialParam bplapply
#' @importFrom S4Vectors List
testClonotypeCountsPairwise <- function(counts, 
    downsample=TRUE, down.ncells=NULL, 
    iterations=2000, adj.method="holm", BPPARAM=SerialParam()) 
{
    if (downsample) {
        counts <- .downsample_list(counts, down.ncells)
    }

    res <- bplapply(seq_along(counts), BPPARAM=BPPARAM,
        FUN=function(x, counts, use.gini, use.hill, iterations) 
        {
            results <- list() 
            for (y in seq_len(x-1L)) {
                results[[y]] <- .generate_shuffled_diversity_p(counts[[x]], counts[[y]],
                    iterations=iterations)
            }
            results
        }, counts=counts, use.gini=use.gini, use.hill=use.hill, iterations=iterations) 

    output <- list()
    if (length(counts) <= 1L) {
        stop("'counts' should contain at least two groups")
    }
    all.stat.names <- names(res[[2]][[1]])

    for (stat in all.stat.names) {
        current <- matrix(NA_real_, length(counts), length(counts))
        dimnames(current) <- list(names(counts), names(counts))

        for (x in seq_along(res)) {
            for (y in seq_along(res[[x]])) {
                current[x,y] <- res[[x]][[y]][stat]
            }
        }

        current[] <- p.adjust(current, method=adj.method)
        output[[stat]] <- current
    }

    List(output)
}

#' @importFrom S4Vectors Rle runValue runLength
.generate_shuffled_diversity_p <- function(x, y, iterations, use.gini=TRUE, use.hill=0:2) {
    # Clonotypes from different groups are effectively separate things,
    # so we give them different labels to distinguish them.
    labels <- seq_len(length(x) + length(y))
    values <- c(unname(x), unname(y))
    pool <- Rle(labels, values)

    Nx <- sum(x)
    N <- Nx + sum(y)

    if (use.gini) {
        ref.gini <- abs(.compute_gini(x) - .compute_gini(y))
        out.gini <- 0L
    }
    if (length(use.hill)) {
        ref.hill <- abs(calcDiversity(x, use.hill) - calcDiversity(x, use.hill))
        out.hill <- integer(length(ref.hill))
    }

    for (i in seq_len(iterations)) {
        # sorting is VERY important here, to avoid need for re-table()ing.
        chosen <- sort(sample(N, Nx)) 
        left <- pool[chosen]
        right <- pool[-chosen]

        ldistr <- runLength(left)
        rdistr <- runLength(right)

        if (use.gini) {
            out.gini <- out.gini + abs(.compute_gini(ldistr) - .compute_gini(rdistr))
        }
        if (length(use.hill)) {
            out.hill <- out.hill + abs(calcDiversity(ldistr, use.hill) - calcDiversity(rdistr, use.hill))
        }
    }

    # Using Phipson & Smyth's approach:
    output <- numeric(0)
    if (use.gini) {
        output["gini"] <- (out.gini + 1)/(iterations+1)
    }
    if (length(use.hill)) {
        output[sprintf("hill%i", use.hill)] <- (out.hill + 1)/(iterations+1)
    }
    output
}