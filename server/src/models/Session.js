const mongoose = require('mongoose');

const sessionSchema = new mongoose.Schema({
  userId: {
    type: mongoose.Schema.Types.ObjectId,
    ref: 'User',
    required: true
  },
  startTime: {
    type: Date,
    required: true
  },
  endTime: {
    type: Date
  },
  totalFocusTime: {
    type: Number,
    default: 0
  },
  totalDistractionTime: {
    type: Number,
    default: 0
  },
  pieceName: {
    type: String,
    required: true
  },
  improvements: {
    type: String
  },
  notes: {
    type: String
  },
  distractions: [{
    startTime: Date,
    endTime: Date,
    description: String,
    duration: Number
  }],
  createdAt: {
    type: Date,
    default: Date.now
  },
  updatedAt: {
    type: Date,
    default: Date.now
  }
});

// 更新时间中间件
sessionSchema.pre('save', function(next) {
  this.updatedAt = Date.now();
  next();
});

module.exports = mongoose.model('Session', sessionSchema); 