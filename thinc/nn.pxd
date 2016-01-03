cimport cython
from libc.string cimport memset, memcpy
from libc.math cimport sqrt as c_sqrt
from libc.stdint cimport int32_t
import numpy
import numpy.random

from cymem.cymem cimport Pool

from preshed.maps cimport map_init as Map_init
from preshed.maps cimport map_get as Map_get
from preshed.maps cimport map_set as Map_set

from .structs cimport NeuralNetC, OptimizerC, FeatureC, BatchC, ExampleC, EmbeddingC, MapC
from .typedefs cimport weight_t
from .blas cimport Vec, MatMat, MatVec, VecVec
from .eg cimport Batch, Example

cdef extern from "math.h" nogil:
    float expf(float x)

DEF EPS = 0.000001 
DEF ALPHA = 1.0
# The input/output of the fwd/bwd pass can be confusing. Some notes.
#
# Forward pass. in0 is at fwd_state[0]. Activation of layer 1 is
# at fwd_state[1]
# 
# in0 = input_
# in1 = act0 = ReLu(in0 * W0 + b0)
# in2 = act1 = ReLu(in1 * W1 + b1)
# out = act2 = Softmax(in2 * W2 + b2)

# Okay so our scores are at fwd_state[3]. Our loss will live there too.
# The loss will then be used to calculate the gradient for layer 2.
# We now sweep backward, and calculate the next loss, which will be used
# to calculate the gradient for layer 1, etc.
#
# So, the total loss is at bwd_state[3]
# 
# g2 = d3 = out - target
# g1 = d2 = Back(d3, in2, w2, b2)
# g0 = d1 = Back(d2, in1, w1, b1)
# gE = d0 = Back(d1, in0, w0, b0)
# 
# gE here refers to the 'fine tuning' vector, for word embeddings


cdef class NeuralNet:
    cdef Pool mem
    cdef NeuralNetC c

    @staticmethod
    cdef inline int nr_weight(int nr_out, int nr_wide) nogil:
        # Account for beta and gamma weights, for batch normalization
        return nr_out * nr_wide + nr_out * 3

    @staticmethod
    cdef inline void predictC(ExampleC* egs,
            int nr_eg, const NeuralNetC* nn) nogil:
        for i in range(nr_eg):
            eg = &egs[i]
            if nn.embeds is not NULL and eg.features is not NULL:
                Embedding.set_input(eg.fwd_state[0],
                    eg.features, eg.nr_feat, nn.embeds)
            NeuralNet.forward(eg.fwd_state, nn.fwd_mean, nn.fwd_variance,
                nn.weights, nn.widths, nn.nr_layer, nn.alpha)
            Example.set_scores(eg,
                eg.fwd_state[nn.nr_layer-1])
     
    @staticmethod
    cdef inline void updateC(NeuralNetC* nn, weight_t* gradient, ExampleC* egs,
            int nr_eg) nogil:
        for i in range(nr_eg):
            eg = &egs[i]
            NeuralNet.backward(eg.bwd_state, nn.bwd_mean, nn.bwd_mean2,
                eg.costs, eg.fwd_state, nn.fwd_mean, nn.weights + nn.nr_weight,
                nn.widths, nn.nr_layer, nn.alpha)
        for i in range(nr_eg):
            NeuralNet.set_gradient(gradient,
                egs[i].fwd_state, egs[i].bwd_state, nn.widths, nn.nr_layer, nn.alpha)
        nn.opt.update(nn.opt, nn.weights, gradient,
            1.0 / nr_eg, nn.nr_weight)
        # Fine-tune the embeddings
        # This is sort of wrong --- we're supposed to average over the minibatch.
        # However, most words are rare --- so most words will only have non-zero
        # gradient for 1 or 2 examples anyway.
        if nn.embeds is not NULL:
            for i in range(nr_eg):
                eg = &egs[i]
                if eg.features is not NULL:
                    Embedding.fine_tune(nn.opt, nn.embeds, eg.fine_tune,
                        eg.bwd_state[0], nn.widths[0], eg.features, eg.nr_feat)
 
    @staticmethod
    cdef inline void insert_embeddingsC(NeuralNetC* nn, Pool mem,
            const ExampleC* egs, int nr_eg) except *:
        for i in range(nr_eg):
            eg = &egs[i]
            for j in range(eg.nr_feat):
                feat = eg.features[j]
                emb = <weight_t*>Map_get(nn.embeds.tables[feat.i], feat.key)
                if emb is NULL:
                    emb = <weight_t*>mem.alloc(nn.embeds.lengths[feat.i], sizeof(weight_t))
                    Initializer.normal(emb,
                        0.0, 1.0, nn.embeds.lengths[feat.i])
                    Map_set(mem, nn.embeds.tables[feat.i], feat.key, emb)
  
    @staticmethod
    cdef inline void forward(weight_t** fwd, weight_t** ema_E_fwd,
                            weight_t** ema_V_fwd, const weight_t* W, const int* widths,
                            int n, weight_t alpha) nogil:
        cdef const weight_t* bn_scale
        cdef const weight_t* bn_shift
        cdef int nr_out = 0
        cdef int nr_in = 0
        cdef int i = 0
        while Fwd.iter(&i, &W, &bn_scale, &bn_shift, &nr_out, &nr_in, widths, n):
            MatVec.dot(fwd[i],
                W, fwd[i-1], nr_out, nr_in)
            Fwd.estimate_normalizers(ema_E_fwd[i], ema_V_fwd[i],
                fwd[i], alpha, nr_out)
            Fwd.normalize(fwd[i],
                ema_E_fwd[i], ema_V_fwd[i], nr_out)
            # Scale-and-shift for the normalization
            # We have to keep fwd[i]'s value intact, so that we can backprop
            VecVec.mul(fwd[i+1],
                fwd[i], bn_scale, nr_out)
            VecVec.add_i(fwd[i+1],
                bn_shift, 1.0, nr_out)
            Fwd.elu(fwd[i+1],
                nr_out)
        Fwd.linear(fwd[n-1],
            fwd[n-2], W, W+(widths[n-1] * widths[n-2]), widths[n-1], widths[n-2])
        Fwd.softmax(fwd[n-1],
            widths[n-1])

    @staticmethod
    cdef inline void backward(weight_t** bwd, weight_t** ema_E_bwd,
            weight_t** ema_E_bwd_dot_fwd,
            const weight_t* costs, const weight_t* const* fwd,
            const weight_t* const* ema_V_fwd, const weight_t* W,
            const int* widths, int n, weight_t alpha) nogil:
        # Layers go:
        # 0. in u
        # 1. A1 x = Wu+b
        # 2. A2 u = y = elu(BN(x))
        # 3. B1 x = Wu+b
        # 4. B2 u = y = elu(BN(x))
        # 5. S  u = softmax(Wu)
        # Pre-iter: Bwd.softmax places the top loss in 5
        # Iter 0: Read from 5 write dL/dY to 4, dL/dX to 3
        # Iter 1: Read from 3, write dL/dY to 2, dL/dX to 1
        # Post-iter: Write dL/dX to 0 for fine-tuning
        Bwd.softmax(bwd[n-1],
            costs, fwd[n-1], widths[n-1])
        cdef const weight_t* bn_scale
        cdef const weight_t* bn_shift
        cdef int nr_out = 0
        cdef int nr_in = 0
        cdef int i = 0
        while Bwd.iter(&i, &W, &bn_scale, &nr_out, &nr_in, widths, n):
            Bwd.linear(bwd[i],
                bwd[i+1], W, nr_out, nr_in)
            Bwd.elu(bwd[i], # bwd[i] is set to dE/dY
                fwd[i], nr_out)
            # This sets up dE/dX' in bwd[i-1]
            VecVec.mul(bwd[i-1],
                bwd[i], bn_scale, nr_out)
            # These need to be estimators of mean(dE/dX') and mean(dE/dX' \cdot X')
            Bwd.estimate_normalizers(ema_E_bwd[i], ema_E_bwd_dot_fwd[i],
                bwd[i-1], ema_V_fwd[i], alpha, nr_out)
            # Backprop through the normalization, to recover dE/dX from dE/X'
            Bwd.normalize(bwd[i-1],
                ema_E_bwd[i], ema_E_bwd_dot_fwd[i], ema_V_fwd[i-1], fwd[i-1], nr_out)
        Bwd.linear(bwd[0],
            bwd[1], W, widths[0], widths[1])
   
    @staticmethod
    cdef inline void set_gradient(weight_t* gradient,
            const weight_t* const* fwd,
            const weight_t* const* bwd,
            const int* widths, int n, weight_t norm_weight) nogil:
        pass
        #cdef int i
        #while ??.iter(&i, &lyr, fwd, bwd, gradient, widths, n):
        #    # Gradient of synapse weights
        #    MatMat.add_outer_i(lyr.W,
        #        lyr.dLdX, lyr.X, lyr.nr_out, lyr.nr_wide)
        #    # Gradient of bias weights
        #    VecVec.add_i(lyr.bias,
        #        lyr.dLdX, 1.0, lyr.nr_out)
        #    # Gradient of gammas
        #    VecVec.add_outer_i(lyr.bn_scale,
        #        lyr.dLdY, lyr.X_hat, lyr.nr_out, 1.0)
        #    # Gradient of betas
        #    VecVec.add_i(lyr.bn_shift,
        #        lyr.dLdY, 1.0, lyr.nr_out)


cdef class Fwd:
    @staticmethod
    cdef inline int iter(int* i, const weight_t** W, const weight_t** bn_scale,
            const weight_t** bn_shift, int* nr_out, int* nr_in,
            const int* widths, int n) nogil:
        pass

    @staticmethod
    cdef inline void linear(weight_t* out,
            const weight_t* in_, const weight_t* W, const weight_t* bias,
            int nr_out, int nr_wide) nogil:
        MatVec.dot(out,
            W, in_, nr_out, nr_wide)
        VecVec.add_i(out,
            bias, 1.0, nr_out)

    @staticmethod
    cdef inline void normalize(weight_t* x,
            const weight_t* E_x, const weight_t* V_x, int n) nogil:
        for i in range(n):
            x[i] = (x[i] - E_x[i]) / c_sqrt(V_x[i] + EPS)

    @staticmethod
    cdef inline void estimate_normalizers(weight_t* ema_E_x, weight_t* ema_V_x,
            const weight_t* x, weight_t alpha, int n) nogil:
        # Upd EMA estimate of mean
        Vec.mul_i(ema_E_x,
            alpha, n)
        VecVec.add_i(ema_E_x,
            x, 1-alpha, n)
        # Upd EMA estimate of variance
        Vec.mul_i(ema_V_x,
            alpha, n)
        for i in range(n):
            ema_V_x[i] += (1.0 - alpha) * (x[i] - ema_E_x[i]) ** 2

    @staticmethod
    cdef inline void relu(weight_t* out,
            int nr_out) nogil:
        cdef int i
        for i in range(nr_out):
            if not (out[i] > 0):
                out[i] = 0

    @staticmethod
    cdef inline void elu(weight_t* out,
            int nr_out) nogil:
        cdef int i
        for i in range(nr_out):
            if out[i] < 0:
                out[i] = ALPHA * (expf(out[i])-1)

    @staticmethod
    cdef inline void residual(weight_t* out,
            const weight_t* const* prev, const int* widths, int i) nogil:
        pass
        #if nr_in == nr_out:
        #    VecVec.add_i(out,
        #        in_, 1.0, nr_out)

    @staticmethod
    cdef inline void softmax(weight_t* out,
            int nr_out) nogil:
        #w = exp(w - max(w))
        Vec.add_i(out,
            -Vec.max(out, nr_out), nr_out)
        Vec.exp_i(out,
            nr_out)
        #w = w / sum(w)
        cdef weight_t norm = Vec.sum(out, nr_out)
        if norm != 0:
            Vec.div_i(out,
                norm, nr_out)


cdef class Bwd:
    @staticmethod
    cdef inline int iter(int* i, const weight_t** W, const weight_t** bn_scale,
            int* nr_out, int* nr_in, const int* widths, int n) nogil:
        pass

    @staticmethod
    cdef inline void softmax(weight_t* loss,
            const weight_t* costs, const weight_t* scores, int nr_out) nogil:
        # This assumes only one true class
        cdef int i
        for i in range(nr_out):
            loss[i] = scores[i] - (costs[i] == 0)

    @staticmethod
    cdef inline void relu(weight_t* delta,
            const weight_t* x, int nr_wide) nogil:
        cdef int i
        for i in range(nr_wide):
            if not (x[i] > 0):
                delta[i] = 0

    @staticmethod
    cdef inline void elu(weight_t* delta,
            const weight_t* x, int nr_wide) nogil:
        cdef int i
        for i in range(nr_wide):
            if x[i] < 0:
                delta[i] *= x[i] + ALPHA

    @staticmethod
    cdef inline void linear(weight_t* delta_out,
            const weight_t* delta_in, const weight_t* W, int nr_out, int nr_wide) nogil:
        MatVec.T_dot(delta_out,
            W, delta_in, nr_out, nr_wide)

    @staticmethod
    cdef inline void normalize(weight_t* bwd,
            const weight_t* E_bwd, const weight_t* E_bwd_dot_fwd,
            const weight_t* X_hat, const weight_t* V_x, int n) nogil:
        # Simplification taken from Caffe, I think by cdoersch
        # if X' = (X-mean(X))/sqrt(var(X)+eps), then
        # dE/dX =
        #   (dE/dX' - mean(dE/dX') - mean(dE/dX' * X') * X')
        #     ./ sqrt(var(X) + eps)
        # Here:
        # bwd is dE/dX' to start with. We change it to dE/dX in-place.
        # mean(dE/dX_) is E_bwd, and mean(dE/dX_ * X_) is E_bwd_dot_fwd
        # V_x is var(x)
        for i in range(n):
            bwd[i] -= E_bwd[i] - E_bwd_dot_fwd[i] * X_hat[i]
            bwd[i] /= c_sqrt(V_x[i] + EPS)

    @staticmethod
    cdef inline void estimate_normalizers(weight_t* E_bwd, weight_t* E_bwd_dot_fwd,
            const weight_t* bwd, const weight_t* fwd, weight_t alpha, int n) nogil:
        # Update EMA estimate of mean(dL/dX_hat)
        Vec.mul_i(E_bwd,
            alpha, n)
        VecVec.add_i(E_bwd,
            bwd, 1-alpha, n)
        # Update EMA estimate of mean(dE/dX_hat \cdot X_hat)
        Vec.mul_i(E_bwd_dot_fwd,
            alpha, n)
        for i in range(n):
            E_bwd_dot_fwd[i] += (1-alpha) * bwd[i] * fwd[i]


cdef class Embedding:
    cdef Pool mem
    cdef EmbeddingC* c

    @staticmethod
    cdef inline void init(EmbeddingC* self, Pool mem, vector_widths, features) except *: 
        assert max(features) < len(vector_widths)
        # Create tables, which may be shared between different features
        # e.g., we might have a feature for this word, and a feature for next
        # word. These occupy different parts of the input vector, but draw
        # from the same embedding table.
        uniqs = <MapC*>mem.alloc(len(vector_widths), sizeof(MapC))
        uniq_defaults = <weight_t**>mem.alloc(len(vector_widths), sizeof(void*))
        for i, width in enumerate(vector_widths):
            Map_init(mem, &uniqs[i], 8)
            uniq_defaults[i] = <weight_t*>mem.alloc(width, sizeof(weight_t))
            Initializer.normal(uniq_defaults[i],
                0.0, 1.0, width)
        self.offsets = <int*>mem.alloc(len(features), sizeof(int))
        self.lengths = <int*>mem.alloc(len(features), sizeof(int))
        self.tables = <MapC**>mem.alloc(len(features), sizeof(void*))
        self.defaults = <weight_t**>mem.alloc(len(features), sizeof(void*))
        offset = 0
        for i, table_id in enumerate(features):
            self.tables[i] = &uniqs[table_id]
            self.lengths[i] = vector_widths[table_id]
            self.defaults[i] = uniq_defaults[table_id]
            self.offsets[i] = offset
            offset += vector_widths[table_id]

    @staticmethod
    cdef inline void set_input(weight_t* out, const FeatureC* features, int nr_feat,
            const EmbeddingC* layer) nogil:
        for i in range(nr_feat):
            feat = features[i]
            emb = <weight_t*>Map_get(layer.tables[feat.i], feat.key)
            if emb == NULL:
                emb = layer.defaults[feat.i]
            VecVec.add_i(&out[layer.offsets[feat.i]], 
                emb, feat.val, layer.lengths[feat.i])

    @staticmethod
    cdef inline void fine_tune(OptimizerC* opt, EmbeddingC* layer, weight_t* fine_tune,
                               const weight_t* delta, int nr_delta,
                               const FeatureC* features, int nr_feat) nogil:
        for i in range(nr_feat):
            # Reset fine_tune, because we need to modify the gradient
            memcpy(fine_tune, delta, sizeof(weight_t) * nr_delta)
            feat = features[i]
            weights = <weight_t*>Map_get(layer.tables[feat.i], feat.key)
            gradient = &fine_tune[layer.offsets[feat.i]]
            # TODO: Currently we can't store supporting parameters for the word
            # vectors in opt, so we can only do vanilla SGD. In practice this
            # seems to work very well!
            VanillaSGD.update(opt, weights, gradient,
                feat.val, layer.lengths[feat.i])


cdef class Initializer:
    @staticmethod
    cdef inline void normal(weight_t* weights, weight_t loc, weight_t scale, int n) except *:
        # See equation 10 here:
        # http://arxiv.org/pdf/1502.01852v1.pdf
        values = numpy.random.normal(loc=0.0, scale=scale, size=n)
        for i, value in enumerate(values):
            weights[i] = value

    @staticmethod
    cdef inline void constant(weight_t* weights, weight_t value, int n) nogil:
        for i in range(n):
            weights[i] = value


cdef class VanillaSGD:
    @staticmethod
    cdef inline void init(OptimizerC* self, Pool mem, int nr_weight, int* widths,
            int nr_layer, weight_t eta, weight_t eps, weight_t rho) except *:
        self.update = VanillaSGD.update
        self.eta = eta
        self.eps = eps
        self.rho = rho
        self.params = NULL
        self.ext = NULL
        self.nr = 0

    @staticmethod
    cdef inline void update(OptimizerC* opt, weight_t* weights, weight_t* gradient,
            weight_t scale, int nr_weight) nogil:
        '''
        Update weights with vanilla SGD
        '''
        Vec.mul_i(gradient, scale, nr_weight)
        # Add the derivative of the L2-loss to the gradient
        if opt.rho != 0:
            VecVec.add_i(gradient,
                weights, opt.rho, nr_weight)

        VecVec.add_i(weights,
            gradient, -opt.eta, nr_weight)


cdef class Adagrad:
    @staticmethod
    cdef inline void init(OptimizerC* self, Pool mem, int nr_weight, int* widths,
            int nr_layer, weight_t eta, weight_t eps, weight_t rho) except *:
        self.update = Adagrad.update
        self.eta = eta
        self.eps = eps
        self.rho = rho
        self.params = <weight_t*>mem.alloc(nr_weight, sizeof(weight_t))
        self.ext = NULL
        self.nr = 0

    @staticmethod
    cdef inline void update(OptimizerC* opt, weight_t* weights, weight_t* gradient,
            weight_t scale, int nr_weight) nogil:
        '''
        Update weights with vanilla SGD
        '''
        # Add the derivative of the L2-loss to the gradient
        cdef int i
        if opt.rho != 0:
            VecVec.add_i(gradient,
                weights, opt.rho, nr_weight)
        VecVec.add_pow_i(opt.params,
            gradient, 2.0, nr_weight)
        for i in range(nr_weight):
            gradient[i] *= opt.eta / (c_sqrt(opt.params[i]) + opt.eps)
        Vec.mul_i(gradient,
            scale, nr_weight)
        # Make the (already scaled) update
        VecVec.add_i(weights,
            gradient, -1.0, nr_weight)
